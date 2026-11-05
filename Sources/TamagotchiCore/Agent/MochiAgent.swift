import Foundation
import TamagotchiWire

// Mochi's personal agent: new mail, coming meetings and Notion tasks, read through the user's own
// Claude connectors (signed in on claude.ai) by a short background `claude -p` — Haiku, read-only
// tools, the user's Claude subscription, nothing saved. Mochi says what matters in a speech bubble
// and, if allowed, on the iPhone.

// MARK: Settings

public struct AgentSettings: Codable, Sendable, Equatable {
    public var enabled = false
    /// What Mochi watches; a source also has to be connected in the user's Claude account.
    public var watched: [AgentSource] = AgentSource.allCases
    public var intervalMinutes = 15
    /// No checks in this window (overnight by default).
    public var quietHours = QuietHours(enabled: true, startMinute: 23 * 60, endMinute: 8 * 60)
    public var briefingEnabled = true
    /// Minutes after midnight.
    public var briefingMinute = 9 * 60
    public var tellInBubble = true
    public var tellWithBadge = true
    public var tellPhone = true
    /// Newsletters and automated mail stay off the iPhone.
    public var phoneSkipsLowPriority = true
    /// Mochi Cloud's API trigger (its token is in the Keychain), shared with Mochi Pocket for "Check now".
    public var cloudFireURL = ""
    /// People whose mail always rings through (names, addresses or "@domain"); with none, any mail that
    /// matters does. Everyone else waits for the morning and night summaries.
    public var vips: [String] = []
    /// Marking an email done also marks it read in Gmail, so no check brings it back.
    public var markReadWhenDone = true

    public static let intervals = [5, 10, 15, 30, 60]

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AgentSettings()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? defaults.enabled
        if let names = try? container.decodeIfPresent([String].self, forKey: .watched) {
            watched = names.compactMap(AgentSource.init(rawValue:))
        }
        intervalMinutes = (try? container.decodeIfPresent(Int.self, forKey: .intervalMinutes)).flatMap { $0 }.map { max(5, $0) }
            ?? defaults.intervalMinutes
        quietHours = (try? container.decodeIfPresent(QuietHours.self, forKey: .quietHours)) ?? defaults.quietHours
        briefingEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .briefingEnabled)) ?? defaults.briefingEnabled
        briefingMinute = (try? container.decodeIfPresent(Int.self, forKey: .briefingMinute)).flatMap { $0 }.map(QuietHours.clamp)
            ?? defaults.briefingMinute
        tellInBubble = (try? container.decodeIfPresent(Bool.self, forKey: .tellInBubble)) ?? defaults.tellInBubble
        tellWithBadge = (try? container.decodeIfPresent(Bool.self, forKey: .tellWithBadge)) ?? defaults.tellWithBadge
        tellPhone = (try? container.decodeIfPresent(Bool.self, forKey: .tellPhone)) ?? defaults.tellPhone
        phoneSkipsLowPriority = (try? container.decodeIfPresent(Bool.self, forKey: .phoneSkipsLowPriority)) ?? defaults.phoneSkipsLowPriority
        cloudFireURL = (try? container.decodeIfPresent(String.self, forKey: .cloudFireURL)).flatMap { $0 } ?? defaults.cloudFireURL
        vips = ((try? container.decodeIfPresent([String].self, forKey: .vips)).flatMap { $0 } ?? defaults.vips)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        markReadWhenDone = (try? container.decodeIfPresent(Bool.self, forKey: .markReadWhenDone)) ?? defaults.markReadWhenDone
    }

    public func watches(_ source: AgentSource) -> Bool { watched.contains(source) }

    public mutating func setWatching(_ source: AgentSource, _ on: Bool) {
        watched.removeAll { $0 == source }
        if on { watched = AgentSource.allCases.filter { $0 == source || watched.contains($0) } }
    }
}

// MARK: Sources

public enum AgentSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case gmail, calendar, notion

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .gmail: return "Gmail"
        case .calendar: return "Google Calendar"
        case .notion: return "Notion"
        }
    }

    public var symbol: String {
        switch self {
        case .gmail: return "envelope"
        case .calendar: return "calendar"
        case .notion: return "checklist"
        }
    }

    /// The connector's name in Claude Code.
    public var connectorName: String { "claude.ai " + title }

    /// What the agent reads from it, in the words Settings shows.
    public var whatMochiSees: String {
        switch self {
        case .gmail: return "Sender, subject and first lines of new mail in your inbox"
        case .calendar: return "Title, time and place of your coming events"
        case .notion: return "Titles and due dates of open tasks assigned to you"
        }
    }

    /// The only tools the agent may call: reading, never sending, editing or deleting.
    public var readTools: [String] {
        let prefix = "mcp__claude_ai_" + title.replacingOccurrences(of: " ", with: "_") + "__"
        switch self {
        case .gmail: return ["search_threads", "get_thread", "get_message", "list_labels"].map { prefix + $0 }
        case .calendar: return ["list_events", "get_event", "search_events", "list_calendars"].map { prefix + $0 }
        case .notion: return ["notion-search", "notion-fetch", "notion-get-self", "notion-query-data-sources"].map { prefix + $0 }
        }
    }
}

// MARK: Running Claude

public enum AgentMode: Sendable, Equatable {
    /// What arrived since the last check, and what starts soon.
    case check(since: Date)
    /// The day at a glance: the morning briefing, or "what's pending?".
    case briefing
}

public enum AgentCommand {
    public static let model = "haiku"

    /// `claude -p` reading the prompt from stdin. `dontAsk` refuses every tool not listed here, so the
    /// run can read and nothing else; none of the user's settings or hooks load and nothing is saved.
    public static func arguments(sources: [AgentSource]) -> [String] {
        ["-p", "--model", model, "--output-format", "json", "--setting-sources", "project", "--no-session-persistence",
         "--permission-mode", "dontAsk", "--tools", "ToolSearch",
         "--allowedTools", "ToolSearch"] + sources.flatMap(\.readTools) + ["--json-schema", schema]
    }

    /// The user's claude.ai connectors load in `-p` runs only when asked for, and otherwise connect in the
    /// background — racing the model, which then finds no tools. Waiting for them first makes every run see
    /// them. An API key in the environment would bill the run to the API instead of the user's
    /// subscription: never pass one on.
    public static func environment(from base: [String: String]) -> [String: String] {
        var environment = base
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"] {
            environment[key] = nil
        }
        environment["ENABLE_CLAUDEAI_MCP_SERVERS"] = "true"
        environment["MCP_CONNECTION_NONBLOCKING"] = "false"
        return environment
    }

    public static func prompt(mode: AgentMode, sources: [AgentSource], now: Date, timeZone: TimeZone = .current) -> String {
        var lines = [
            "You are the background checker for Mochi, a desktop pet that tells its owner what needs their attention. "
                + "Read only: never send, change or delete anything.",
            "The Gmail, Calendar and Notion tools can take a few seconds to connect; if one isn't loaded yet, use tool search to load it.",
            "Now: \(localTime(now, timeZone)) (\(timeZone.identifier), UTC\(offset(timeZone, at: now))).",
        ]
        let briefing = mode == .briefing
        if sources.contains(.gmail) {
            let query: String
            if case .check(let since) = mode {
                query = "is:unread in:inbox after:\(Int(since.timeIntervalSince1970))"
            } else {
                query = "is:unread in:inbox newer_than:1d"
            }
            lines.append("Gmail: search_threads with the query \"\(query)\" (at most 15 threads). For each give the thread id, the "
                         + "sender's display name as the From line shows it (\"VFDF via Figma\", \"Google\") — never the email address — "
                         + "and, separately, the sender's email address, the subject, a gist of at most 12 words, urgency (high: a person needs something from the "
                         + "owner soon; low: newsletters, promotions, receipts and other automated mail; normal: the rest) and whether "
                         + "it needs a reply. Judge from the search results; open a thread only when the snippet isn't enough, at most 3 times.")
        } else {
            lines.append("Gmail is not part of this check: return an empty emails list.")
        }
        if sources.contains(.calendar) {
            let until = briefing ? endOfDay(now, timeZone) : now.addingTimeInterval(90 * 60)
            lines.append("Google Calendar: list_events on the primary calendar from now until \(iso(until, timeZone)). Skip all-day "
                         + "events and events the owner declined. Give each event's id, title, start and end (ISO 8601 with offset) "
                         + "and place if any, and the video call link (Google Meet, Zoom or Teams URL) as link if any.")
        } else {
            lines.append("Google Calendar is not part of this check: return an empty events list.")
        }
        if sources.contains(.notion) {
            let window = briefing ? "due today, overdue, or due within the next 2 days" : "due today or overdue"
            lines.append("Notion: find open task-like items (not done) assigned to the owner that are \(window): notion-get-self, "
                         + "then notion-search. At most 4 Notion calls; if nothing obvious turns up, return an empty tasks list.")
        } else {
            lines.append("Notion is not part of this check: return an empty tasks list.")
        }
        lines.append(briefing
            ? "Headline: at most 110 characters, a friendly summary of the owner's day, the most important thing first."
            : "Headline: at most 110 characters, the most important new thing first, e.g. \"3 new emails — the invoice from Acme needs a reply today\".")
        lines.append("Use ids exactly as the tools return them. Reply with the JSON only.")
        return lines.joined(separator: "\n")
    }

    public static let schema = """
    {"type":"object","additionalProperties":false,"required":["headline","emails","events","tasks"],"properties":{\
    "headline":{"type":"string"},\
    "emails":{"type":"array","items":{"type":"object","additionalProperties":false,\
    "required":["id","from","subject","gist","urgency","needs_reply"],"properties":{"id":{"type":"string"},"from":{"type":"string"},\
    "address":{"type":"string"},\
    "subject":{"type":"string"},"gist":{"type":"string"},"urgency":{"type":"string","enum":["high","normal","low"]},\
    "needs_reply":{"type":"boolean"}}}},\
    "events":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","title","start"],\
    "properties":{"id":{"type":"string"},"title":{"type":"string"},"start":{"type":"string"},"end":{"type":"string"},\
    "where":{"type":"string"},"link":{"type":"string"}}}},\
    "tasks":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","title"],\
    "properties":{"id":{"type":"string"},"title":{"type":"string"},"due":{"type":"string"},"status":{"type":"string"},\
    "url":{"type":"string"}}}}}}
    """

    static func localTime(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func iso(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func offset(_ timeZone: TimeZone, at date: Date) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        return String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
    }

    static func endOfDay(_ date: Date, _ timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }
}

// MARK: What Claude found

public struct AgentDigest: Codable, Sendable, Equatable {
    public var headline: String
    public var emails: [AgentEmail]
    public var events: [AgentEvent]
    public var tasks: [AgentTask]

    public init(headline: String, emails: [AgentEmail] = [], events: [AgentEvent] = [], tasks: [AgentTask] = []) {
        self.headline = headline
        self.emails = emails
        self.events = events
        self.tasks = tasks
    }

    /// The digest in `claude -p --output-format json`'s `structured_output`, cleaned up; nil when the run failed.
    public static func parse(output data: Data) -> AgentDigest? {
        guard let output = AnyJSON.parse(data), output["is_error"]?.boolValue != true,
              let structured = output["structured_output"], let json = try? JSONEncoder().encode(structured),
              let digest = try? JSONDecoder().decode(AgentDigest.self, from: json) else { return nil }
        return digest.cleaned()
    }

    /// Why a run failed, in Claude Code's words, when it says.
    public static func failure(output data: Data) -> String? {
        guard let output = AnyJSON.parse(data) else { return nil }
        if output["is_error"]?.boolValue == true { return WireText.clean(output["result"]?.stringValue, maxLength: 200) ?? "Claude reported an error." }
        if output["structured_output"] == nil { return "Claude didn't return a digest." }
        return nil
    }

    func cleaned() -> AgentDigest {
        func text(_ value: String, _ length: Int) -> String { WireText.clean(value, maxLength: length) ?? "" }
        return AgentDigest(
            headline: text(headline, 140),
            emails: emails.prefix(20).compactMap { email in
                guard !email.id.isEmpty else { return nil }
                return AgentEmail(id: email.id, from: text(AgentEmail.senderName(email.from), 60), subject: text(email.subject, 120),
                                  gist: text(email.gist, 120),
                                  urgency: ["high", "normal", "low"].contains(email.urgency) ? email.urgency : "normal", needsReply: email.needsReply,
                                  address: AgentEmail.address(email.address ?? email.from))
            },
            events: events.prefix(20).compactMap { event in
                guard !event.id.isEmpty else { return nil }
                return AgentEvent(id: event.id, title: text(event.title, 100), start: text(event.start, 40), end: event.end.map { text($0, 40) },
                                  place: event.place.flatMap { WireText.clean($0, maxLength: 120) },
                                  link: event.link.flatMap { $0.hasPrefix("https://") && $0.count <= 200 && !$0.contains(" ") ? $0 : nil })
            },
            tasks: tasks.prefix(20).compactMap { task in
                guard !task.id.isEmpty else { return nil }
                return AgentTask(id: task.id, title: text(task.title, 120), due: task.due.flatMap { WireText.clean($0, maxLength: 40) },
                                 status: task.status.flatMap { WireText.clean($0, maxLength: 40) }, url: task.url)
            })
    }
}

public struct AgentEmail: Codable, Sendable, Equatable {
    public var id: String
    public var from: String
    public var subject: String
    public var gist: String
    /// high · normal · low
    public var urgency: String
    public var needsReply: Bool
    /// The sender's email address, for VIPs (never shown).
    public var address: String?

    public init(id: String, from: String, subject: String, gist: String, urgency: String = "normal", needsReply: Bool = false,
                address: String? = nil) {
        self.id = id
        self.from = from
        self.subject = subject
        self.gist = gist
        self.urgency = urgency
        self.needsReply = needsReply
        self.address = address
    }

    enum CodingKeys: String, CodingKey {
        case id, from, subject, gist, urgency, address
        case needsReply = "needs_reply"
    }

    /// The plain address in "Name <a@b.com>" or "a@b.com", lowercased.
    public static func address(_ raw: String) -> String? {
        var text = raw
        if let open = text.firstIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            text = String(text[text.index(after: open)..<close])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")).lowercased()
        guard text.contains("@"), !text.contains(" "), text.count <= 120 else { return nil }
        return text
    }

    /// Needs the owner: urgent, or someone waiting for an answer.
    public var important: Bool { urgency == "high" || needsReply }

    /// The name people know a sender by: "VFDF via Figma <comments-…@email.figma.com>" → "VFDF via Figma",
    /// and a bare address → its company ("no-reply@accounts.google.com" → "Google").
    public static func senderName(_ raw: String) -> String {
        let quotes = CharacterSet(charactersIn: " \"'")
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let open = text.firstIndex(of: "<") {
            let name = text[..<open].trimmingCharacters(in: quotes)
            if !name.isEmpty { return name }
            text = String(text[text.index(after: open)...]).trimmingCharacters(in: CharacterSet(charactersIn: "> "))
        }
        if let paren = text.firstIndex(of: "("), text.contains("@") {
            let before = text[..<paren].trimmingCharacters(in: quotes)
            let inside = text[text.index(after: paren)...].trimmingCharacters(in: CharacterSet(charactersIn: ") \"'"))
            if !before.isEmpty, !before.contains("@") { return before }
            if !inside.isEmpty, !inside.contains("@") { return inside }
            text = before
        }
        text = text.trimmingCharacters(in: quotes)
        guard text.contains("@"), !text.contains(" "), let domain = text.split(separator: "@").last else { return text }
        var labels = domain.lowercased().split(separator: ".").map(String.init)
        // "shop.co.uk": the name sits before a two-part ending.
        if labels.count >= 3, labels[labels.count - 1].count == 2, ["co", "com", "org", "net", "ac", "gov"].contains(labels[labels.count - 2]) {
            labels.removeLast()
        }
        let company = labels.count >= 2 ? labels[labels.count - 2] : (labels.first ?? text)
        return knownNames[company] ?? company.prefix(1).uppercased() + company.dropFirst()
    }

    static let knownNames = ["clevertap": "CleverTap", "github": "GitHub", "linkedin": "LinkedIn", "youtube": "YouTube",
                             "paypal": "PayPal", "hubspot": "HubSpot", "openai": "OpenAI", "icloud": "iCloud", "zoho": "Zoho",
                             "whatsapp": "WhatsApp", "facebookmail": "Facebook", "amazonses": "Amazon"]

    var rank: Int { (urgency == "high" ? 2 : urgency == "normal" ? 1 : 0) + (needsReply ? 1 : 0) }
}

public struct AgentEvent: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    /// ISO 8601 with offset.
    public var start: String
    public var end: String?
    public var place: String?
    /// The video call to join (Google Meet, Zoom, Teams).
    public var link: String?

    public init(id: String, title: String, start: String, end: String? = nil, place: String? = nil, link: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.place = place
        self.link = link
    }

    enum CodingKeys: String, CodingKey {
        case id, title, start, end, link
        case place = "where"
    }

    public var startDate: Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: start) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: start)
    }
}

public struct AgentTask: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var due: String?
    public var status: String?
    public var url: String?

    public init(id: String, title: String, due: String? = nil, status: String? = nil, url: String? = nil) {
        self.id = id
        self.title = title
        self.due = due
        self.status = status
        self.url = url
    }
}

// MARK: Connections

public enum AgentConnection: String, Sendable, Equatable {
    case connected, needsSignIn, failed, unavailable

    public var title: String {
        switch self {
        case .connected: return "Connected"
        case .needsSignIn: return "Needs sign-in"
        case .failed: return "Couldn't connect"
        case .unavailable: return "Not connected"
        }
    }
}

public enum AgentConnections {
    /// Where the user connects these services: their Claude account's connectors.
    public static let connectURL = URL(string: "https://claude.ai/customize/connectors")!

    /// Claude Code fetches the claude.ai connectors in the background, after its first report, so the only
    /// reliable way to know is to ask: a tiny Haiku run that looks for each connector's tools and calls none.
    public static var probeArguments: [String] {
        ["-p", "--model", AgentCommand.model, "--output-format", "json", "--setting-sources", "project", "--no-session-persistence",
         "--permission-mode", "dontAsk", "--tools", "ToolSearch", "--allowedTools", "ToolSearch", "--json-schema", probeSchema]
    }

    public static let probePrompt = """
    Find out which of these connectors' tools are available to you, using tool search only: Gmail (tools named \
    mcp__claude_ai_Gmail__…), Google Calendar (mcp__claude_ai_Google_Calendar__…) and Notion (mcp__claude_ai_Notion__…). \
    Connectors can take a few seconds to connect: if one isn't found, search for it once more. Don't call any of their tools. \
    Reply with the JSON only: true for each connector with at least one tool available.
    """

    static let probeSchema = """
    {"type":"object","additionalProperties":false,"required":["gmail","calendar","notion"],\
    "properties":{"gmail":{"type":"boolean"},"calendar":{"type":"boolean"},"notion":{"type":"boolean"}}}
    """

    /// Each source's state from the probe's output; nil when the run failed.
    public static func parse(probeOutput data: Data) -> [AgentSource: AgentConnection]? {
        guard let output = AnyJSON.parse(data), output["is_error"]?.boolValue != true,
              let found = output["structured_output"]?.objectValue else { return nil }
        var states: [AgentSource: AgentConnection] = [:]
        for source in AgentSource.allCases {
            states[source] = found[source.rawValue]?.boolValue == true ? .connected : .unavailable
        }
        return states
    }

    /// Claude Code remembers a connector that needed signing in and skips it in `-p` runs for a while,
    /// even after the user has connected it. Forgets that note for these sources only, before a fresh look.
    @discardableResult
    public static func forgetSignInNotes(cacheFile: URL) -> Bool {
        guard let data = try? Data(contentsOf: cacheFile),
              var cache = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        let names = Set(AgentSource.allCases.map(\.connectorName))
        let before = cache.count
        cache = cache.filter { !names.contains($0.key) }
        guard cache.count != before, let updated = try? JSONSerialization.data(withJSONObject: cache) else { return false }
        return (try? updated.write(to: cacheFile, options: .atomic)) != nil
    }
}

// MARK: What Mochi has told you

/// One thing Mochi told the user, as Settings lists it.
public struct AgentNote: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var source: AgentSource
    public var title: String
    public var detail: String
    public var important: Bool
    public var at: Double
    /// When an event starts (Unix time): the Pending card drops it once it's over.
    public var due: Double?
    /// Where tapping it goes: the Gmail thread or the Notion page.
    public var link: String?
    /// An email's subject line.
    public var subject: String?
    /// From one of your VIPs.
    public var vip: Bool?

    public init(id: String, source: AgentSource, title: String, detail: String, important: Bool, at: Double,
                due: Double? = nil, link: String? = nil, subject: String? = nil, vip: Bool? = nil) {
        self.id = id
        self.source = source
        self.title = title
        self.detail = detail
        self.important = important
        self.at = at
        self.due = due
        self.link = link
        self.subject = subject
        self.vip = vip
    }

    /// A Gmail thread's id, for "mail:<id>" notes.
    public var threadID: String? { source == .gmail && id.hasPrefix("mail:") ? String(id.dropFirst(5)) : nil }
}

/// People whose mail always rings through.
public enum AgentVIP {
    /// An entry with "@" is an address, or a domain when it starts with "@"; anything else is part of a name.
    public static func matches(_ email: AgentEmail, _ vips: [String]) -> Bool {
        let address = email.address?.lowercased() ?? ""
        let name = email.from.lowercased()
        return vips.contains { raw in
            let vip = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !vip.isEmpty else { return false }
            if vip.hasPrefix("@") { return address.hasSuffix(vip) }
            if vip.contains("@") { return address == vip }
            return name.contains(vip)
        }
    }

    /// The same list as a Gmail search: from:("Amogh Sharma" OR a@b.com OR insideedge.club).
    public static func gmailQuery(_ vips: [String]) -> String? {
        let terms = vips.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { vip -> String in
            let term = vip.hasPrefix("@") ? String(vip.dropFirst()) : vip
            return term.contains(" ") ? "\"" + term.replacingOccurrences(of: "\"", with: "") + "\"" : term
        }
        return terms.isEmpty ? nil : "from:(" + terms.joined(separator: " OR ") + ")"
    }
}

/// The Pending card in Mochi Pocket: what's waiting for you as of the Mac's last look. It travels
/// through your iCloud (`macAgent`) and inside each agent notification, which lands sooner.
public struct AgentPending: Codable, Sendable, Equatable {
    /// The Mac shares it (the agent is on, with "On my iPhone").
    public var enabled: Bool
    public var headline: String?
    public var items: [AgentNote]
    /// When the Mac last looked (Unix time).
    public var lookedAt: Double?
    /// When the Mac wrote this, so the phone keeps the newest of iCloud and a notification.
    public var updatedAt: Double?
    /// nil from the Mac; "cloud" from an hourly Mochi Cloud run (only what's new that hour), "cloud-manual"
    /// from "Check now" answered in the cloud (the whole day).
    public var origin: String?

    public static let maxItems = 8

    public init(enabled: Bool, headline: String? = nil, items: [AgentNote] = [], lookedAt: Double? = nil, updatedAt: Double? = nil,
                origin: String? = nil) {
        self.enabled = enabled
        self.headline = headline
        self.items = items
        self.lookedAt = lookedAt
        self.updatedAt = updatedAt
        self.origin = origin
    }

    /// A newer card folded into this one: the Mac's and a "Check now" card replace it; an hourly cloud
    /// card only adds what it found (it never looked at the rest).
    public func merging(_ newer: AgentPending, now: Date = Date()) -> AgentPending {
        guard newer.origin == "cloud" else { return newer }
        var memory = AgentMemory()
        memory.pending = items
        memory.pendingHeadline = headline
        memory.updatePending(with: newer.items, replacing: false, headline: nil, now: now)
        var card = self
        card.enabled = enabled || newer.enabled
        card.items = memory.pending
        card.headline = newer.items.isEmpty ? headline : (newer.headline ?? headline)
        card.lookedAt = max(lookedAt ?? 0, newer.lookedAt ?? 0)
        card.updatedAt = newer.updatedAt
        return card
    }

    public var json: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }
    public static func decode(_ json: String) -> AgentPending? { try? JSONDecoder().decode(AgentPending.self, from: Data(json.utf8)) }

    /// The card an agent notification carries.
    public static func decode(notification info: [AnyHashable: Any]) -> AgentPending? {
        guard let pending = info["pending"], JSONSerialization.isValidJSONObject(pending),
              let data = try? JSONSerialization.data(withJSONObject: pending) else { return nil }
        return try? JSONDecoder().decode(AgentPending.self, from: data)
    }

    /// Small enough to ride in a push (APNs allows 4 KB): fewer items, shorter words.
    public var compact: AgentPending {
        var copy = self
        copy.headline = headline.map { AgentNews.clip($0, to: 120) }
        copy.items = items.prefix(6).map { item in
            var item = item
            item.title = AgentNews.clip(item.title, to: 60)
            item.detail = AgentNews.clip(item.detail, to: 90)
            item.subject = item.subject.map { AgentNews.clip($0, to: 70) }
            if (item.link?.count ?? 0) > 200 { item.link = nil }
            return item
        }
        return copy
    }
}

/// What's new in a digest: everything Mochi hasn't mentioned yet.
public struct AgentNews: Sendable, Equatable {
    public var emails: [AgentEmail] = []
    public var events: [AgentEvent] = []
    public var tasks: [AgentTask] = []
    /// With VIPs, only their mail rings; the rest waits for the summaries.
    public var vips: [String] = []

    public init(emails: [AgentEmail] = [], events: [AgentEvent] = [], tasks: [AgentTask] = [], vips: [String] = []) {
        self.emails = emails.sorted { a, b in
            let (va, vb) = (AgentVIP.matches(a, vips), AgentVIP.matches(b, vips))
            return va != vb ? va : a.rank > b.rank
        }
        self.events = events
        self.tasks = tasks
        self.vips = vips
    }

    public func isVIP(_ email: AgentEmail) -> Bool { !vips.isEmpty && AgentVIP.matches(email, vips) }

    public var isEmpty: Bool { emails.isEmpty && events.isEmpty && tasks.isEmpty }

    /// How loudly Mochi should say it: nothing for newsletters alone.
    public var attention: AttentionLevel? {
        if !vips.isEmpty {
            if emails.contains(where: isVIP) || !events.isEmpty { return .attention }
            return tasks.isEmpty ? nil : .info
        }
        if emails.contains(where: \.important) || !events.isEmpty { return .attention }
        if !tasks.isEmpty || emails.contains(where: { $0.urgency != "low" }) { return .info }
        return nil
    }

    /// Worth buzzing the iPhone for.
    public func worthPhone(skippingLow: Bool) -> Bool {
        guard skippingLow else { return !isEmpty }
        return attention != nil
    }

    /// The parts of what Mochi says, most important first.
    public func parts(timeZone: TimeZone = .current) -> [String] {
        var urgent: [String] = []
        var rest: [String] = []
        if let top = emails.first {
            let count = emails.count
            var text: String
            if emails.allSatisfy({ $0.urgency == "low" }) {
                text = count == 1 ? "New email from \(top.from), nothing urgent" : "\(count) new emails, nothing urgent"
            } else {
                text = count == 1 ? "New email from \(top.from): \(top.gist)" : "\(count) new emails · \(top.from): \(top.gist)"
                if top.needsReply { text += " (needs a reply)" }
            }
            if top.important { urgent.append(text) } else { rest.append(text) }
        }
        if let event = events.first {
            var text = event.title
            if let start = event.startDate { text += " at " + Self.time(start, timeZone) }
            if events.count > 1 { text += " (+\(events.count - 1) more)" }
            urgent.append(text)
        }
        if let task = tasks.first {
            rest.insert(tasks.count == 1 ? "Due in Notion: \(task.title)" : "\(tasks.count) Notion tasks due · \(task.title)", at: 0)
        }
        return urgent + rest
    }

    /// Mochi's speech bubble: the most important part, kept short.
    public func line(timeZone: TimeZone = .current) -> String {
        let parts = parts(timeZone: timeZone)
        guard let first = parts.first else { return "" }
        let more = parts.count > 1 ? " · and more" : ""
        return Self.clip(first, to: 120 - more.count) + more
    }

    /// The iPhone notification: a title and a few lines.
    public func notification(timeZone: TimeZone = .current) -> (title: String, body: String) {
        let parts = parts(timeZone: timeZone)
        let title: String
        if !emails.isEmpty, events.isEmpty, tasks.isEmpty {
            title = emails.count == 1 ? "New email" : "\(emails.count) new emails"
        } else if !events.isEmpty, emails.isEmpty, tasks.isEmpty {
            title = "Coming up"
        } else if !tasks.isEmpty, emails.isEmpty, events.isEmpty {
            title = "Due in Notion"
        } else {
            title = "Mochi has news"
        }
        var lines = parts.prefix(3).map { Self.clip($0, to: 140) }
        for email in emails.dropFirst().filter(\.important).prefix(2) {
            lines.append(Self.clip("\(email.from): \(email.gist)", to: 140))
        }
        return (title, lines.joined(separator: "\n"))
    }

    public func notes(at date: Date, timeZone: TimeZone = .current) -> [AgentNote] {
        let at = date.timeIntervalSince1970.rounded()
        var notes = emails.map {
            AgentNote(id: "mail:" + $0.id, source: .gmail, title: $0.from, detail: $0.gist.isEmpty ? $0.subject : $0.gist,
                      important: $0.important || isVIP($0), at: at, link: Self.gmailLink($0.id),
                      subject: $0.subject.isEmpty || $0.gist.isEmpty ? nil : $0.subject, vip: isVIP($0) ? true : nil)
        }
        notes += events.map {
            AgentNote(id: "event:" + $0.id, source: .calendar, title: $0.title,
                      detail: ($0.startDate.map { Self.time($0, timeZone) } ?? $0.start) + ($0.place.map { " · \($0)" } ?? ""),
                      important: true, at: at, due: $0.startDate?.timeIntervalSince1970, link: $0.link)
        }
        notes += tasks.map {
            AgentNote(id: "task:" + $0.id, source: .notion, title: $0.title, detail: $0.due.map { "Due \($0)" } ?? "Open",
                      important: false, at: at, link: $0.url.flatMap { $0.hasPrefix("https://") ? $0 : nil })
        }
        return notes
    }

    /// Gmail on the web (or the Gmail app) at that thread, in the default account.
    static func gmailLink(_ threadID: String) -> String? {
        guard !threadID.isEmpty, threadID.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return "https://mail.google.com/mail/#all/" + threadID
    }

    static func time(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    static func clip(_ text: String, to length: Int) -> String {
        text.count <= length ? text : String(text.prefix(max(1, length - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// What Mochi has already mentioned (so nothing is said twice) and when it last looked.
public struct AgentMemory: Codable, Sendable, Equatable {
    /// "mail:<id>", "event:<id>" or "task:<id>:<day>" → when Mochi first mentioned it (Unix time).
    public var seen: [String: Double] = [:]
    public var lastCheckAt: Double?
    public var lastBriefingDay: String?
    /// Newest first.
    public var notes: [AgentNote] = []
    /// What's waiting for you now (the Pending card), in the order it's shown.
    public var pending: [AgentNote] = []
    public var pendingHeadline: String?
    /// What you marked done, here or on the iPhone (item id → when): it never comes back.
    public var done: [String: Double] = [:]
    /// Gmail threads already marked read after you marked them done.
    public var markedRead: [String: Double] = [:]

    public static let keepDays = 14.0
    public static let maxNotes = 40
    /// Mail and tasks leave the Pending card after this long, unless a briefing brings them back.
    public static let pendingHours = 30.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seen = (try? container.decodeIfPresent([String: Double].self, forKey: .seen)) ?? [:]
        lastCheckAt = try? container.decodeIfPresent(Double.self, forKey: .lastCheckAt)
        lastBriefingDay = try? container.decodeIfPresent(String.self, forKey: .lastBriefingDay)
        notes = (try? container.decodeIfPresent([AgentNote].self, forKey: .notes)) ?? []
        pending = (try? container.decodeIfPresent([AgentNote].self, forKey: .pending)) ?? []
        pendingHeadline = try? container.decodeIfPresent(String.self, forKey: .pendingHeadline)
        done = (try? container.decodeIfPresent([String: Double].self, forKey: .done)) ?? [:]
        markedRead = (try? container.decodeIfPresent([String: Double].self, forKey: .markedRead)) ?? [:]
    }

    /// Done items leave the Pending card and won't be mentioned again. Returns whether anything was new.
    @discardableResult
    public mutating func markDone(_ ids: [String: Double]) -> Bool {
        let new = ids.filter { done[$0.key] == nil }
        guard !new.isEmpty else { return false }
        done.merge(new) { old, _ in old }
        for id in new.keys { seen[id] = seen[id] ?? new[id] }
        pending.removeAll { done[$0.id] != nil }
        if pending.isEmpty { pendingHeadline = nil }
        return true
    }

    /// Done Gmail threads that still need marking read.
    public var threadsToMarkRead: [String] {
        done.keys.filter { $0.hasPrefix("mail:") }.map { String($0.dropFirst(5)) }.filter { markedRead[$0] == nil }.sorted()
    }

    /// A briefing replaces the Pending card; a check adds what's new to it.
    public mutating func updatePending(with notes: [AgentNote], replacing: Bool, headline: String?, now: Date) {
        let notes = notes.filter { done[$0.id] == nil }
        if replacing {
            pending = notes
            pendingHeadline = headline
        } else if !notes.isEmpty {
            let ids = Set(notes.map(\.id))
            pending = notes + pending.filter { !ids.contains($0.id) }
        }
        prunePending(now: now)
    }

    /// Events go once they've started (plus ten minutes), the rest after `pendingHours`. Returns whether anything changed.
    @discardableResult
    public mutating func prunePending(now: Date) -> Bool {
        let before = pending
        let time = now.timeIntervalSince1970
        pending = Self.ordered(pending.filter { note in
            if let due = note.due { return due > time - 600 }
            return note.at > time - Self.pendingHours * 3600
        })
        pending = Array(pending.prefix(AgentPending.maxItems))
        if pending.isEmpty, before.isEmpty == false { pendingHeadline = nil }
        return pending != before
    }

    /// Coming events first (soonest first), then what needs you, then tasks, then the rest (newest first).
    public static func ordered(_ notes: [AgentNote]) -> [AgentNote] {
        func group(_ note: AgentNote) -> Int {
            if note.source == .calendar { return 0 }
            if note.important { return 1 }
            return note.source == .notion ? 2 : 3
        }
        return notes.sorted { a, b in
            let (ga, gb) = (group(a), group(b))
            if ga != gb { return ga < gb }
            if ga == 0 { return (a.due ?? .infinity) < (b.due ?? .infinity) }
            return a.at > b.at
        }
    }

    /// The digest's items Mochi hasn't mentioned yet; they count as mentioned from now on. Notion tasks
    /// come back once a day while they stay open.
    public mutating func news(from digest: AgentDigest, now: Date, vips: [String] = [], calendar: Calendar = .current) -> AgentNews {
        let day = AgentSchedule.dayKey(now, calendar: calendar)
        let at = now.timeIntervalSince1970
        func fresh(_ key: String, _ item: String) -> Bool {
            guard seen[key] == nil, done[item] == nil else { return false }
            seen[key] = at
            return true
        }
        return AgentNews(emails: digest.emails.filter { fresh("mail:" + $0.id, "mail:" + $0.id) },
                         events: digest.events.filter { fresh("event:" + $0.id, "event:" + $0.id) },
                         tasks: digest.tasks.filter { fresh("task:\($0.id):\(day)", "task:" + $0.id) }, vips: vips)
    }

    /// Marks everything in a briefing as mentioned, so the next check doesn't repeat it.
    public mutating func markSeen(_ digest: AgentDigest, now: Date, calendar: Calendar = .current) {
        _ = news(from: digest, now: now, calendar: calendar)
    }

    public mutating func remember(_ notes: [AgentNote]) {
        let ids = Set(notes.map(\.id))
        self.notes = Array((notes + self.notes.filter { !ids.contains($0.id) }).prefix(Self.maxNotes))
    }

    public mutating func prune(now: Date) {
        let cutoff = now.timeIntervalSince1970 - Self.keepDays * 86_400
        seen = seen.filter { $0.value >= cutoff }
        notes = notes.filter { $0.at >= cutoff }
        done = done.filter { $0.value >= cutoff }
        markedRead = markedRead.filter { $0.value >= cutoff }
    }

    public static func load(from url: URL) -> AgentMemory {
        guard let data = try? Data(contentsOf: url), let memory = try? JSONDecoder().decode(AgentMemory.self, from: data) else {
            return AgentMemory()
        }
        return memory
    }

    public func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// What one device marked done, shared through iCloud ("phoneDone" from Mochi Pocket, "macDone" from the Mac);
/// each side keeps the union.
public struct AgentDoneList: Codable, Sendable, Equatable {
    public var ids: [String: Double]

    public static let maxItems = 300

    public init(ids: [String: Double] = [:]) {
        self.ids = ids
    }

    /// The newest marks from the last week, few enough for one iCloud value.
    public func trimmed(now: Date = Date()) -> AgentDoneList {
        let cutoff = now.timeIntervalSince1970 - 7 * 86_400
        let kept = ids.filter { $0.value >= cutoff }.sorted { $0.value > $1.value }.prefix(Self.maxItems)
        return AgentDoneList(ids: Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) }))
    }

    public var json: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }
    public static func decode(_ json: String) -> AgentDoneList? { try? JSONDecoder().decode(AgentDoneList.self, from: Data(json.utf8)) }
}

extension AgentCommand {
    /// A run that may only remove the UNREAD label from the threads you marked done.
    public static let markReadTool = "mcp__claude_ai_Gmail__unlabel_thread"

    public static var markReadArguments: [String] {
        ["-p", "--model", model, "--output-format", "json", "--setting-sources", "project", "--no-session-persistence",
         "--permission-mode", "dontAsk", "--tools", "ToolSearch", "--allowedTools", "ToolSearch", markReadTool]
    }

    public static func markReadPrompt(threadIDs: [String]) -> String {
        "Mark these Gmail threads as read: for each thread id, call unlabel_thread with labelIds [\"UNREAD\"]. Do nothing else; "
            + "if the tool isn't loaded yet, use tool search to load it. Thread ids: " + threadIDs.joined(separator: ", ")
            + ". Finish with one line saying how many you marked."
    }

    /// The mark-read run finished without an error.
    public static func markReadSucceeded(output data: Data) -> Bool {
        guard let output = AnyJSON.parse(data) else { return false }
        return output["is_error"]?.boolValue != true && output["result"] != nil
    }
}

// MARK: When to look

public enum AgentSchedule {
    public static func checkDue(_ settings: AgentSettings, lastCheck: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard settings.enabled, !settings.quietHours.isActive(at: now, calendar: calendar) else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= Double(max(5, settings.intervalMinutes)) * 60 - 5
    }

    /// Once a day, from the chosen time until three hours later (a Mac that slept through it still briefs).
    public static func briefingDue(_ settings: AgentSettings, lastBriefingDay: String?, now: Date, calendar: Calendar = .current) -> Bool {
        guard settings.enabled, settings.briefingEnabled, !settings.quietHours.isActive(at: now, calendar: calendar),
              dayKey(now, calendar: calendar) != lastBriefingDay else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minute >= settings.briefingMinute && minute < settings.briefingMinute + 180
    }

    /// Where a check picks up: a little before the last one, so nothing slips between them.
    public static func since(lastCheck: Date?, now: Date) -> Date {
        guard let lastCheck, now.timeIntervalSince(lastCheck) < 86_400 else { return now.addingTimeInterval(-2 * 3600) }
        return lastCheck.addingTimeInterval(-120)
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

// MARK: Mochi Cloud

/// Mochi Cloud: a Claude Code scheduled task (claude.ai/code/routines) that does the agent's check hourly in
/// Anthropic's cloud while this Mac is off, and pushes straight to Mochi Pocket (see the mochi-cloud repository).
public enum AgentCloud {
    /// Where scheduled tasks' API triggers live.
    public static let fireURLPrefix = "https://api.anthropic.com/v1/claude_code/routines/"

    /// The cloud environment's variables, ready to paste: the push key (base64), where to push and the time zone.
    public static func environmentBlock(keyPEM: String, keyID: String, teamID: String, deviceToken: String, topic: String,
                                        sandbox: Bool, timeZone: TimeZone = .current) -> String {
        [
            "MOCHI_APNS_KEY_B64=" + Data(keyPEM.utf8).base64EncodedString(),
            "MOCHI_APNS_KEY_ID=" + keyID,
            "MOCHI_TEAM_ID=" + teamID,
            "MOCHI_DEVICE_TOKEN=" + deviceToken,
            "MOCHI_TOPIC=" + topic,
            "MOCHI_APNS_HOST=" + (sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"),
            "MOCHI_TIMEZONE=" + timeZone.identifier,
        ].joined(separator: "\n")
    }

    /// Mochi Cloud as a `cloud` device in the Mochi Link room (docs/MOCHI_LINK_PLAN.md 4.8): it seals its news with
    /// the room key and posts it to the relay, which pushes it to the phone. No push key and no phone address.
    public static func linkEnvironmentBlock(_ credentials: LinkCredentials, timeZone: TimeZone = .current) -> String {
        [
            "MOCHI_LINK_RELAY=" + credentials.relay,
            "MOCHI_LINK_ROOM=" + credentials.room,
            "MOCHI_LINK_DEVICE=" + credentials.device,
            "MOCHI_LINK_SECRET=" + credentials.secret,
            "MOCHI_LINK_KEY=" + credentials.key,
            "MOCHI_TIMEZONE=" + timeZone.identifier,
        ].joined(separator: "\n")
    }

    /// "AuthKey_PBGWR4LQA9.p8" → "PBGWR4LQA9".
    public static func keyID(fromFileName name: String) -> String? {
        guard name.hasPrefix("AuthKey_"), name.hasSuffix(".p8") else { return nil }
        let id = String(name.dropFirst("AuthKey_".count).dropLast(".p8".count))
        return id.count == 10 && id.allSatisfy({ $0.isLetter || $0.isNumber }) ? id : nil
    }

    public static func isFireURL(_ text: String) -> Bool {
        guard text.hasPrefix(fireURLPrefix), text.hasSuffix("/fire"), let url = URL(string: text) else { return false }
        return url.host == "api.anthropic.com"
    }
}

// MARK: iPhone

extension PhoneAlertPayload {
    public static let agentCategory = "mochi-agent"

    /// Mochi's news as an ordinary notification, with the Pending card riding along (iCloud can take minutes).
    /// Mochi Pocket's notification extension sees each one (`mutable-content`); with `quietIfKnown`, one that
    /// brings nothing already told (by this Mac or Mochi Cloud) arrives without a sound or banner.
    public static func agentNews(title: String, body: String, pending: AgentPending? = nil, quietIfKnown: Bool = false) -> Data {
        let aps: [String: AnyJSON] = [
            "alert": ["title": .string(title), "body": .string(body)],
            "sound": "default",
            "category": .string(agentCategory),
            "thread-id": .string(agentCategory),
            "mutable-content": 1,
        ]
        var payload: [String: AnyJSON] = ["aps": .object(aps), "kind": "agent", "quietIfKnown": .bool(quietIfKnown)]
        if let pending, let data = try? JSONEncoder().encode(pending.compact), let json = AnyJSON.parse(data) { payload["pending"] = json }
        return Data(AnyJSON.object(payload).jsonText.utf8)
    }
}

// MARK: Read aloud

/// What Mochi Pocket's speaker button says: meetings first, then mail that needs you, the rest in a line,
/// then Notion tasks. Plain sentences, short enough to listen to in under a minute.
public enum AgentSpeech {
    public static func script(items: [AgentNote], timeZone: TimeZone = .current) -> String {
        guard !items.isEmpty else { return "Nothing is waiting for you right now. Enjoy!" }
        var sentences = [items.count == 1 ? "One thing is waiting for you." : "\(items.count) things are waiting for you."]
        let events = items.filter { $0.source == .calendar }.sorted { ($0.due ?? .infinity) < ($1.due ?? .infinity) }
        let mail = items.filter { $0.source == .gmail }
        let important = mail.filter(\.important)
        let rest = mail.filter { !$0.important }
        let tasks = items.filter { $0.source == .notion }
        for event in events.prefix(3) {
            let when = event.due.map { AgentNews.time(Date(timeIntervalSince1970: $0), timeZone) }
            sentences.append(when.map { "\(event.title), at \($0)." } ?? "\(event.title).")
        }
        if events.count > 3 { sentences.append("And \(events.count - 3) more meetings.") }
        for email in important.prefix(4) {
            sentences.append("\(email.title) needs you: \(spoken(email.subject ?? email.detail)).")
        }
        if important.count > 4 { sentences.append("And \(important.count - 4) more emails that need you.") }
        switch rest.count {
        case 0: break
        case 1, 2: rest.forEach { sentences.append("From \($0.title): \(spoken($0.detail)).") }
        default:
            let names = Array(Set(rest.map(\.title))).sorted().prefix(2).joined(separator: " and ")
            sentences.append("And \(rest.count) more emails, nothing urgent, from \(names) and others.")
        }
        for task in tasks.prefix(3) { sentences.append("Due in Notion: \(spoken(task.title)).") }
        if tasks.count > 3 { sentences.append("And \(tasks.count - 3) more tasks.") }
        sentences.append("That's everything.")
        return sentences.joined(separator: " ")
    }

    /// Without trailing punctuation or symbols a voice would read out ("·", "…").
    static func spoken(_ text: String) -> String {
        var line = text.replacingOccurrences(of: " · ", with: ", ").replacingOccurrences(of: "…", with: "")
        while let last = line.last, ".!?,;: ".contains(last) { line.removeLast() }
        return line
    }
}
