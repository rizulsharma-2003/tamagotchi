import Foundation
import Testing
@testable import TamagotchiCore

@Suite("Mochi's agent")
struct AgentTests {
    private let utc = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    // MARK: Settings

    @Test func settingsDecodeTolerantly() throws {
        let json = #"{"enabled": true, "watched": ["gmail", "fax", "notion"], "intervalMinutes": 2, "briefingMinute": 1500}"#
        let settings = try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))
        #expect(settings.enabled)
        #expect(settings.watched == [.gmail, .notion])
        #expect(settings.intervalMinutes == 5)
        #expect(settings.briefingMinute == 60)
        #expect(settings.tellPhone)
        let empty = try JSONDecoder().decode(AgentSettings.self, from: Data("{}".utf8))
        #expect(empty == AgentSettings())
    }

    @Test func appSettingsWithoutAnAgentKeepTheDefaults() throws {
        let data = try JSONEncoder().encode(AppSettings())
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["agent"] = nil
        let decoded = AppSettings.decodeTolerantly(try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.agent == AgentSettings())
        #expect(!decoded.agent.enabled)
    }

    @Test func watchingKeepsTheUsualOrder() {
        var settings = AgentSettings()
        settings.setWatching(.gmail, false)
        #expect(settings.watched == [.calendar, .notion])
        settings.setWatching(.gmail, true)
        #expect(settings.watched == [.gmail, .calendar, .notion])
    }

    // MARK: The Claude run

    @Test func onlyReadToolsAreAllowed() {
        let arguments = AgentCommand.arguments(sources: AgentSource.allCases)
        #expect(arguments.contains("dontAsk"))
        #expect(arguments.contains("mcp__claude_ai_Gmail__search_threads"))
        #expect(arguments.contains("mcp__claude_ai_Google_Calendar__list_events"))
        #expect(arguments.contains("mcp__claude_ai_Notion__notion-search"))
        for tool in ["send_message", "reply", "forward", "create_draft", "trash_thread", "create_event", "delete_event",
                     "notion-update-page", "notion-delete-pages", "notion-create-pages"] {
            #expect(!arguments.contains { $0.hasSuffix("__" + tool) }, "\(tool) must never be allowed")
        }
        let gmailOnly = AgentCommand.arguments(sources: [.gmail])
        #expect(!gmailOnly.contains { $0.contains("Notion") || $0.contains("Calendar") })
        #expect(gmailOnly.contains("--setting-sources") && gmailOnly.contains("--no-session-persistence"))
    }

    @Test func runsOnTheSubscriptionNeverAnAPIKey() {
        let environment = AgentCommand.environment(from: ["ANTHROPIC_API_KEY": "sk-test", "ANTHROPIC_AUTH_TOKEN": "t",
                                                          "ANTHROPIC_BASE_URL": "https://example.com", "PATH": "/usr/bin",
                                                          "MCP_CONNECTION_NONBLOCKING": "true"])
        #expect(environment["MCP_CONNECTION_NONBLOCKING"] == "false", "connectors must be ready before the model looks")
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(environment["ANTHROPIC_BASE_URL"] == nil)
        #expect(environment["ENABLE_CLAUDEAI_MCP_SERVERS"] == "true")
        #expect(environment["PATH"] == "/usr/bin")
    }

    @Test func aCheckAsksForMailSinceTheLastLook() {
        let now = date("2026-11-03T09:30:00Z")
        let since = date("2026-11-03T09:13:00Z")
        let prompt = AgentCommand.prompt(mode: .check(since: since), sources: [.gmail, .calendar], now: now, timeZone: utc)
        #expect(prompt.contains("is:unread in:inbox after:\(Int(since.timeIntervalSince1970))"))
        #expect(prompt.contains("until 2026-11-03T11:00:00Z"))
        #expect(prompt.contains("Notion is not part of this check"))
        #expect(prompt.contains("Read only"))
    }

    @Test func aBriefingCoversTheWholeDay() {
        let prompt = AgentCommand.prompt(mode: .briefing, sources: AgentSource.allCases, now: date("2026-11-03T09:00:00Z"), timeZone: utc)
        #expect(prompt.contains("newer_than:1d"))
        #expect(prompt.contains("until 2026-11-03T23:59:59Z"))
        #expect(prompt.contains("within the next 2 days"))
    }

    @Test func readsTheDigestFromClaudesOutput() throws {
        let output = """
        {"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"headline":"2 new emails",\
        "emails":[{"id":"t1","from":"Figma","subject":"Mention","gist":"Someone mentioned you","urgency":"normal","needs_reply":true},\
        {"id":"","from":"x","subject":"y","gist":"z","urgency":"low","needs_reply":false},\
        {"id":"t2","from":"Shop","subject":"Sale","gist":"50% off","urgency":"weird","needs_reply":false}],\
        "events":[{"id":"e1","title":"Standup","start":"2026-11-03T10:00:00Z","where":"Zoom"}],"tasks":[]}}
        """
        let digest = try #require(AgentDigest.parse(output: Data(output.utf8)))
        #expect(digest.headline == "2 new emails")
        #expect(digest.emails.map(\.id) == ["t1", "t2"])
        #expect(digest.emails[0].needsReply)
        #expect(digest.emails[1].urgency == "normal")
        #expect(digest.events.first?.place == "Zoom")
        #expect(AgentDigest.failure(output: Data(output.utf8)) == nil)
    }

    @Test func aFailedRunExplainsItself() {
        let output = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Usage limit reached"}"#
        #expect(AgentDigest.parse(output: Data(output.utf8)) == nil)
        #expect(AgentDigest.failure(output: Data(output.utf8)) == "Usage limit reached")
    }

    // MARK: Connections

    @Test func readsConnectorStatesFromTheProbe() throws {
        let output = #"{"type":"result","is_error":false,"structured_output":{"gmail":true,"calendar":false,"notion":true}}"#
        let states = try #require(AgentConnections.parse(probeOutput: Data(output.utf8)))
        #expect(states[.gmail] == .connected)
        #expect(states[.calendar] == .unavailable)
        #expect(states[.notion] == .connected)
        #expect(AgentConnections.parse(probeOutput: Data(#"{"type":"result","is_error":true,"result":"x"}"#.utf8)) == nil)
        let arguments = AgentConnections.probeArguments
        #expect(arguments.contains("dontAsk"))
        #expect(!arguments.contains { $0.hasPrefix("mcp__") }, "the probe may look, never call")
    }

    @Test func forgetsOnlyItsOwnSignInNotes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("needs-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache: [String: Any] = ["claude.ai Notion": ["timestamp": 1], "claude.ai Slack": ["timestamp": 2],
                                    "claude.ai Google Calendar": ["timestamp": 3]]
        try JSONSerialization.data(withJSONObject: cache).write(to: url)
        #expect(AgentConnections.forgetSignInNotes(cacheFile: url))
        let left = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(left.keys) == ["claude.ai Slack"])
        #expect(!AgentConnections.forgetSignInNotes(cacheFile: url))
    }

    // MARK: Telling the news

    private func digest() -> AgentDigest {
        AgentDigest(headline: "News",
                    emails: [AgentEmail(id: "a", from: "CleverTap", subject: "Maintenance", gist: "Maintenance tomorrow night", urgency: "low"),
                             AgentEmail(id: "b", from: "Figma", subject: "Mention", gist: "Someone mentioned you", urgency: "normal", needsReply: true)],
                    events: [AgentEvent(id: "e", title: "Standup", start: "2026-11-03T10:00:00Z")],
                    tasks: [AgentTask(id: "t", title: "Ship v5", due: "2026-11-03")])
    }

    @Test func saysEachThingOnce() {
        var memory = AgentMemory()
        let now = date("2026-11-03T09:00:00Z")
        let first = memory.news(from: digest(), now: now, calendar: calendar)
        #expect(first.emails.map(\.id) == ["b", "a"])
        #expect(first.events.count == 1 && first.tasks.count == 1)
        let again = memory.news(from: digest(), now: now.addingTimeInterval(900), calendar: calendar)
        #expect(again.isEmpty)
        // An open task comes back the next day; mail and events don't.
        let tomorrow = memory.news(from: digest(), now: now.addingTimeInterval(86_400), calendar: calendar)
        #expect(tomorrow.emails.isEmpty && tomorrow.events.isEmpty)
        #expect(tomorrow.tasks.map(\.id) == ["t"])
    }

    @Test func theMostImportantThingComesFirst() {
        let news = AgentNews(emails: digest().emails, events: digest().events)
        let parts = news.parts(timeZone: utc)
        #expect(parts.first == "2 new emails · Figma: Someone mentioned you (needs a reply)")
        #expect(parts.contains { $0.hasPrefix("Standup at ") })
        #expect(news.line(timeZone: utc).hasSuffix(" · and more"))
        #expect(news.attention == .attention)
        let note = news.notification(timeZone: utc)
        #expect(note.title == "Mochi has news")
        #expect(note.body.contains("Figma"))
    }

    @Test func newslettersAloneStayQuiet() {
        let news = AgentNews(emails: [AgentEmail(id: "a", from: "Shop", subject: "Sale", gist: "50% off", urgency: "low"),
                                      AgentEmail(id: "c", from: "News", subject: "Weekly", gist: "This week", urgency: "low")])
        #expect(news.line() == "2 new emails, nothing urgent")
        #expect(news.attention == nil)
        #expect(!news.worthPhone(skippingLow: true))
        #expect(news.worthPhone(skippingLow: false))
        #expect(news.notification().title == "2 new emails")
    }

    @Test func memoryForgetsOldThings() {
        var memory = AgentMemory()
        let now = Date()
        memory.seen = ["mail:old": now.addingTimeInterval(-20 * 86_400).timeIntervalSince1970, "mail:new": now.timeIntervalSince1970]
        memory.remember([AgentNote(id: "x", source: .gmail, title: "Old", detail: "", important: false,
                                   at: now.addingTimeInterval(-20 * 86_400).timeIntervalSince1970)])
        memory.prune(now: now)
        #expect(Array(memory.seen.keys) == ["mail:new"])
        #expect(memory.notes.isEmpty)
    }

    // MARK: When to look

    @Test func checksOnTheIntervalOutsideQuietHours() {
        var settings = AgentSettings()
        settings.enabled = true
        settings.intervalMinutes = 15
        let morning = date("2026-11-03T10:00:00Z")
        #expect(AgentSchedule.checkDue(settings, lastCheck: nil, now: morning, calendar: calendar))
        #expect(!AgentSchedule.checkDue(settings, lastCheck: morning.addingTimeInterval(-600), now: morning, calendar: calendar))
        #expect(AgentSchedule.checkDue(settings, lastCheck: morning.addingTimeInterval(-900), now: morning, calendar: calendar))
        #expect(!AgentSchedule.checkDue(settings, lastCheck: nil, now: date("2026-11-03T02:00:00Z"), calendar: calendar))
        settings.enabled = false
        #expect(!AgentSchedule.checkDue(settings, lastCheck: nil, now: morning, calendar: calendar))
    }

    @Test func briefsOnceAMorning() {
        var settings = AgentSettings()
        settings.enabled = true
        let early = date("2026-11-03T08:30:00Z")
        let nine = date("2026-11-03T09:05:00Z")
        let evening = date("2026-11-03T18:00:00Z")
        #expect(!AgentSchedule.briefingDue(settings, lastBriefingDay: nil, now: early, calendar: calendar))
        #expect(AgentSchedule.briefingDue(settings, lastBriefingDay: nil, now: nine, calendar: calendar))
        #expect(!AgentSchedule.briefingDue(settings, lastBriefingDay: "2026-11-03", now: nine, calendar: calendar))
        #expect(!AgentSchedule.briefingDue(settings, lastBriefingDay: nil, now: evening, calendar: calendar))
    }

    @Test func picksUpJustBeforeTheLastLook() {
        let now = date("2026-11-03T10:00:00Z")
        #expect(AgentSchedule.since(lastCheck: now.addingTimeInterval(-900), now: now) == now.addingTimeInterval(-1020))
        #expect(AgentSchedule.since(lastCheck: nil, now: now) == now.addingTimeInterval(-7200))
        #expect(AgentSchedule.since(lastCheck: now.addingTimeInterval(-3 * 86_400), now: now) == now.addingTimeInterval(-7200))
    }

    // MARK: iPhone

    @Test func phoneNotificationIsAnOrdinaryAlert() throws {
        let data = PhoneAlertPayload.agentNews(title: "New email", body: "Figma: Someone mentioned you")
        let json = try #require(AnyJSON.parse(data))
        #expect(json["aps"]?["alert"]?["title"]?.stringValue == "New email")
        #expect(json["aps"]?["category"]?.stringValue == "mochi-agent")
        #expect(json["kind"]?.stringValue == "agent")
    }

    @Test func pendingIsAQuickCommand() {
        #expect(QuickCommands.parse("What's pending?") == .agentNews)
        #expect(QuickCommands.parse("hey mochi, check my email please") == .agentNews)
        #expect(QuickCommands.parse("what did i do today") == .recap)
    }
}

@Suite("Mochi's agent: the Pending card")
struct AgentPendingTests {
    private func note(_ id: String, _ source: AgentSource, important: Bool = false, at: Double, due: Double? = nil) -> AgentNote {
        AgentNote(id: id, source: source, title: id, detail: "", important: important, at: at, due: due)
    }

    @Test func aBriefingReplacesAndChecksAdd() {
        var memory = AgentMemory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let t = now.timeIntervalSince1970
        memory.updatePending(with: [note("mail:a", .gmail, at: t), note("task:t", .notion, at: t)], replacing: true, headline: "Your day", now: now)
        #expect(memory.pending.map(\.id) == ["task:t", "mail:a"])
        #expect(memory.pendingHeadline == "Your day")
        memory.updatePending(with: [note("mail:b", .gmail, important: true, at: t + 60), note("event:e", .calendar, at: t + 60, due: t + 1800)],
                             replacing: false, headline: nil, now: now.addingTimeInterval(60))
        #expect(memory.pending.map(\.id) == ["event:e", "mail:b", "task:t", "mail:a"])
        #expect(memory.pendingHeadline == "Your day")
        memory.updatePending(with: [note("mail:c", .gmail, at: t + 120)], replacing: true, headline: "Fresh", now: now.addingTimeInterval(120))
        #expect(memory.pending.map(\.id) == ["mail:c"])
    }

    @Test func startedMeetingsAndOldMailDropOff() {
        var memory = AgentMemory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let t = now.timeIntervalSince1970
        memory.pending = [note("event:soon", .calendar, at: t, due: t + 600), note("event:gone", .calendar, at: t, due: t - 1200),
                          note("mail:old", .gmail, at: t - 31 * 3600), note("mail:new", .gmail, at: t)]
        let changed = memory.prunePending(now: now)
        #expect(changed)
        #expect(memory.pending.map(\.id) == ["event:soon", "mail:new"])
        let again = memory.prunePending(now: now)
        #expect(!again)
    }

    @Test func oldMemoryFilesStillLoad() throws {
        let old = #"{"seen": {"mail:a": 1800000000}, "lastCheckAt": 1800000000, "notes": []}"#
        let memory = try JSONDecoder().decode(AgentMemory.self, from: Data(old.utf8))
        #expect(memory.seen["mail:a"] == 1_800_000_000)
        #expect(memory.pending.isEmpty)
    }

    @Test func theCardRidesInTheNotification() throws {
        let items = (0..<8).map { AgentNote(id: "mail:\($0)", source: .gmail, title: String(repeating: "x", count: 200), detail: "d",
                                            important: true, at: 1, link: "https://mail.google.com/mail/#all/abc\($0)") }
        let card = AgentPending(enabled: true, headline: "2 new emails", items: items, lookedAt: 10, updatedAt: 11)
        let data = PhoneAlertPayload.agentNews(title: "New email", body: "b", pending: card)
        #expect(data.count < 4096)
        let info = try #require(try JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any])
        let decoded = try #require(AgentPending.decode(notification: info))
        #expect(decoded.items.count == 6)
        #expect(decoded.items[0].title.count <= 60)
        #expect(decoded.updatedAt == 11)
        #expect(AgentPending.decode(decoded.json) == decoded)
    }

    @Test func linksOpenGmailAndNotion() {
        let news = AgentNews(emails: [AgentEmail(id: "19a3f2c", from: "Figma", subject: "s", gist: "g")],
                             tasks: [AgentTask(id: "t", title: "Ship", url: "https://www.notion.so/abc"), AgentTask(id: "u", title: "Odd", url: "javascript:x")])
        let notes = news.notes(at: Date())
        #expect(notes.first { $0.id == "mail:19a3f2c" }?.link == "https://mail.google.com/mail/#all/19a3f2c")
        #expect(notes.first { $0.id == "task:t" }?.link == "https://www.notion.so/abc")
        #expect(notes.first { $0.id == "task:u" }?.link == nil)
    }
}

@Suite("Mochi's agent: sender names")
struct AgentSenderTests {
    @Test(arguments: [
        ("VFDF via Figma <comments-lzhpqhzeuzf3nxedxnsjmg@email.figma.com>", "VFDF via Figma"),
        ("\"Rahul Sharma\" <rahul@insideedge.club>", "Rahul Sharma"),
        ("comments-lzhpqhzeuzf3nxedxnsjmg@email.figma.com", "Figma"),
        ("no-reply@accounts.google.com", "Google"),
        ("no-reply@clevertap.com", "CleverTap"),
        ("team@mail.notion.so", "Notion"),
        ("<orders@shop.co.uk>", "Shop"),
        ("Google (no-reply@accounts.google.com)", "Google"),
        ("no-reply@accounts.google.com (Google Accounts)", "Google Accounts"),
        ("Figma", "Figma"),
    ])
    func peopleAndCompaniesByName(raw: String, expected: String) {
        #expect(AgentEmail.senderName(raw) == expected)
    }

    @Test func theDigestShowsNamesAndSubjects() throws {
        let output = """
        {"is_error":false,"structured_output":{"headline":"h","emails":[{"id":"t1","from":"no-reply@accounts.google.com",\
        "subject":"Security alert","gist":"New sign-in on Mac","urgency":"normal","needs_reply":false}],"events":[],"tasks":[]}}
        """
        let digest = try #require(AgentDigest.parse(output: Data(output.utf8)))
        #expect(digest.emails[0].from == "Google")
        let note = try #require(AgentNews(emails: digest.emails).notes(at: Date()).first)
        #expect(note.title == "Google")
        #expect(note.subject == "Security alert")
        #expect(note.detail == "New sign-in on Mac")
    }
}


@Suite("Mochi Cloud")
struct AgentCloudTests {
    /// Made by mochi_cloud.py (the cloud script) from a sample digest.
    static let cloudPush = #"""
{"aps": {"alert": {"title": "Mochi has news", "body": "2 new emails \u00b7 VFDF via Figma: Someone mentioned you in a Figma comment (needs a reply)\nStandup at 5:00 PM"}, "sound": "default", "category": "mochi-agent", "thread-id": "mochi-agent", "mutable-content": 1}, "kind": "agent", "origin": "cloud", "pending": {"enabled": true, "headline": "2 new emails \u2014 VFDF mentioned you in Figma and needs a reply", "items": [{"id": "event:ev1", "source": "calendar", "title": "Standup", "detail": "5:00 PM \u00b7 Google Meet", "important": true, "at": 1793702978.0, "due": 1793705400.0}, {"id": "mail:19a3f2c", "source": "gmail", "title": "VFDF via Figma", "detail": "Someone mentioned you in a Figma comment", "important": true, "at": 1793702978.0, "link": "https://mail.google.com/mail/#all/19a3f2c", "subject": "VFDF mentioned you"}, {"id": "mail:19a3f2d", "source": "gmail", "title": "Google", "detail": "New sign-in on a Mac", "important": false, "at": 1793702978.0, "link": "https://mail.google.com/mail/#all/19a3f2d", "subject": "Security alert"}], "lookedAt": 1793702978.0, "updatedAt": 1793702978.0, "origin": "cloud"}}
"""#

    @Test func theMacReadsTheCloudScriptsCard() throws {
        let info = try #require(try JSONSerialization.jsonObject(with: Data(Self.cloudPush.utf8)) as? [AnyHashable: Any])
        let card = try #require(AgentPending.decode(notification: info))
        #expect(card.origin == "cloud")
        #expect(card.items.map(\.id) == ["event:ev1", "mail:19a3f2c", "mail:19a3f2d"])
        #expect(card.items[1].title == "VFDF via Figma")
        #expect(card.items[1].subject == "VFDF mentioned you")
        #expect(card.items[1].link == "https://mail.google.com/mail/#all/19a3f2c")
        #expect(card.items[0].due != nil)
    }

    @Test func anHourlyCloudCardAddsAndCheckNowReplaces() {
        let now = Date()
        let t = now.timeIntervalSince1970
        let mac = AgentPending(enabled: true, headline: "Your day", items: [
            AgentNote(id: "mail:a", source: .gmail, title: "Figma", detail: "", important: true, at: t)], lookedAt: t - 3600, updatedAt: t - 3600)
        let hourly = AgentPending(enabled: true, headline: "New email from Google", items: [
            AgentNote(id: "mail:b", source: .gmail, title: "Google", detail: "", important: false, at: t)], lookedAt: t, updatedAt: t, origin: "cloud")
        let merged = mac.merging(hourly, now: now)
        #expect(merged.items.map(\.id) == ["mail:a", "mail:b"])
        #expect(merged.lookedAt == t)
        let manual = AgentPending(enabled: true, headline: "Quiet day", items: [], lookedAt: t, updatedAt: t + 1, origin: "cloud-manual")
        #expect(merged.merging(manual) == manual)
        #expect(mac.merging(AgentPending(enabled: true, items: [], updatedAt: t + 2)).items.isEmpty)
    }
}

@Suite("Mochi Cloud settings")
struct AgentCloudSettingsTests {
    @Test func theSettingsBlockHasEverythingTheScriptReads() {
        let pem = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"
        let block = AgentCloud.environmentBlock(keyPEM: pem, keyID: "PBGWR4LQA9", teamID: "CZDJF6N2RH", deviceToken: "ab12",
                                                topic: "com.insideedge.mochi", sandbox: true, timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        let lines = Dictionary(uniqueKeysWithValues: block.split(separator: "\n").map { line -> (String, String) in
            let parts = line.split(separator: "=", maxSplits: 1)
            return (String(parts[0]), String(parts[1]))
        })
        #expect(Set(lines.keys) == ["MOCHI_APNS_KEY_B64", "MOCHI_APNS_KEY_ID", "MOCHI_TEAM_ID", "MOCHI_DEVICE_TOKEN", "MOCHI_TOPIC",
                                     "MOCHI_APNS_HOST", "MOCHI_TIMEZONE"])
        #expect(Data(base64Encoded: lines["MOCHI_APNS_KEY_B64"]!) == Data(pem.utf8))
        #expect(lines["MOCHI_APNS_HOST"] == "api.sandbox.push.apple.com")
        #expect(lines["MOCHI_TIMEZONE"] == "Asia/Kolkata")
    }

    @Test func recognisesKeyFilesAndTriggers() {
        #expect(AgentCloud.keyID(fromFileName: "AuthKey_PBGWR4LQA9.p8") == "PBGWR4LQA9")
        #expect(AgentCloud.keyID(fromFileName: "key.p8") == nil)
        #expect(AgentCloud.isFireURL("https://api.anthropic.com/v1/claude_code/routines/trig_01ABCDEFGHJKLMNOPQRSTUVW/fire"))
        #expect(!AgentCloud.isFireURL("https://example.com/v1/claude_code/routines/trig_1/fire"))
        #expect(!AgentCloud.isFireURL("https://api.anthropic.com/v1/claude_code/routines/trig_1"))
    }

    @Test func macNewsCanBeQuietWhenKnown() throws {
        let check = try #require(AnyJSON.parse(PhoneAlertPayload.agentNews(title: "t", body: "b", quietIfKnown: true)))
        #expect(check["quietIfKnown"]?.boolValue == true)
        #expect(check["aps"]?["mutable-content"]?.numberValue == 1)
        let briefing = try #require(AnyJSON.parse(PhoneAlertPayload.agentNews(title: "Your day", body: "b")))
        #expect(briefing["quietIfKnown"]?.boolValue == false)
    }
}

@Suite("Mochi Watcher")
struct AgentWatcherTests {
    let fire = "https://api.anthropic.com/v1/claude_code/routines/trig_012eNQcMDqqHfiWcYGoXKjts/fire"

    @Test func fillsInTheTriggerAndTimeZone() throws {
        let script = try #require(AgentCloud.watcherScript(fireURL: fire, token: "sk-ant-oat01-abc_DEF-123",
                                                          timeZone: TimeZone(identifier: "Asia/Kolkata")!))
        #expect(script.contains("fireUrl: '\(fire)'"))
        #expect(script.contains("token: 'sk-ant-oat01-abc_DEF-123'"))
        #expect(script.contains("timeZone: 'Asia/Kolkata'"))
        #expect(!script.contains("__"))
        #expect(script.contains("fire_('new ' + since"), "the cloud's CLAUDE.md understands \"new <time>\", \"soon <time>\" and \"check now\"")
        #expect(script.contains("fire_('soon ' + "))
        #expect(script.contains("headsUpMinutes: 10"))
        #expect(script.contains("vips: [],"))
        #expect(script.contains("onEventUpdated()"))
        #expect(script.contains("-category:promotions"))
    }

    @Test func vipsBecomeAJavaScriptList() throws {
        let script = try #require(AgentCloud.watcherScript(fireURL: fire, token: "tok_123456",
                                                          vips: ["Amogh", " @insideedge.club ", "", "a\"b'</script>\n@x.com"]))
        #expect(script.contains(#"vips: ["Amogh","@insideedge.club","a\"b'</script>@x.com"],"#))
        #expect(AgentCloud.vipList([]) == "[]")
        #expect(script.contains("fire_('new ' + since + ' ' + ids"), "the cloud's CLAUDE.md reads \"new <time> <threads>\"")
    }

    @Test func refusesWhatCouldBreakTheScript() {
        #expect(AgentCloud.watcherScript(fireURL: fire, token: "abc'; alert(1); '") == nil)
        #expect(AgentCloud.watcherScript(fireURL: "https://example.com/fire", token: "abc") == nil)
        #expect(AgentCloud.watcherScript(fireURL: fire, token: "") == nil)
    }
}

@Suite("Mochi Pocket: read aloud")
struct AgentSpeechTests {
    private let utc = TimeZone(identifier: "UTC")!

    @Test func meetingsThenWhatNeedsYouThenTheRest() {
        let t = 1_800_000_000.0
        let items = [
            AgentNote(id: "mail:1", source: .gmail, title: "CleverTap", detail: "Maintenance tomorrow night.", important: false, at: t),
            AgentNote(id: "mail:2", source: .gmail, title: "Amogh Sharma", detail: "Mockup and quantities", important: true, at: t,
                      subject: "T-shirt printing order"),
            AgentNote(id: "event:1", source: .calendar, title: "Standup", detail: "", important: true, at: t, due: t + 3600),
            AgentNote(id: "task:1", source: .notion, title: "Ship v5", detail: "Due today", important: false, at: t),
        ]
        let script = AgentSpeech.script(items: items, timeZone: utc)
        #expect(script.hasPrefix("4 things are waiting for you."))
        let standup = script.range(of: "Standup, at")!.lowerBound
        let amogh = script.range(of: "Amogh Sharma needs you: T-shirt printing order.")!.lowerBound
        let clevertap = script.range(of: "From CleverTap: Maintenance tomorrow night.")!.lowerBound
        let task = script.range(of: "Due in Notion: Ship v5.")!.lowerBound
        #expect(standup < amogh && amogh < clevertap && clevertap < task)
        #expect(script.hasSuffix("That's everything."))
    }

    @Test func manyNewslettersBecomeOneLine() {
        let items = ["Shop", "News", "Bank", "Shop"].enumerated().map {
            AgentNote(id: "mail:\($0.offset)", source: .gmail, title: $0.element, detail: "x", important: false, at: 1)
        }
        let script = AgentSpeech.script(items: items)
        #expect(script.contains("And 4 more emails, nothing urgent, from Bank and News and others."))
        #expect(AgentSpeech.script(items: []) == "Nothing is waiting for you right now. Enjoy!")
    }
}

@Suite("Mochi's agent: VIPs, done and replies")
struct AgentVIPDoneTests {
    private func email(_ id: String, _ from: String, _ address: String?, urgency: String = "normal") -> AgentEmail {
        AgentEmail(id: id, from: from, subject: "S", gist: "G", urgency: urgency, address: address)
    }

    @Test func vipsMatchNamesAddressesAndDomains() {
        let amogh = email("1", "Amogh Sharma", "amogh@insideedge.club")
        let figma = email("2", "VFDF via Figma", "comments@figma.com")
        #expect(AgentVIP.matches(amogh, ["amogh"]))
        #expect(AgentVIP.matches(amogh, ["AMOGH@insideedge.club"]))
        #expect(AgentVIP.matches(amogh, ["@insideedge.club"]))
        #expect(!AgentVIP.matches(figma, ["@insideedge.club", "amogh"]))
        #expect(!AgentVIP.matches(email("3", "Someone", nil), ["@insideedge.club"]))
        #expect(!AgentVIP.matches(amogh, ["", "  "]))
        #expect(AgentVIP.gmailQuery(["Amogh Sharma", "@insideedge.club", "a@b.com"]) == #"from:("Amogh Sharma" OR insideedge.club OR a@b.com)"#)
        #expect(AgentVIP.gmailQuery([" "]) == nil)
    }

    @Test func withVIPsOnlyTheirMailRings() {
        let vips = ["@insideedge.club"]
        let boss = email("1", "Amogh", "amogh@insideedge.club", urgency: "normal")
        let loud = email("2", "Stranger", "x@y.com", urgency: "high")
        #expect(AgentNews(emails: [loud], vips: vips).attention == nil)
        #expect(AgentNews(emails: [loud, boss], vips: vips).attention == .attention)
        #expect(AgentNews(emails: [loud, boss], vips: vips).emails.first?.id == "1", "VIPs come first")
        #expect(AgentNews(emails: [loud]).attention == .attention, "without VIPs, urgency decides")
        let notes = AgentNews(emails: [loud, boss], vips: vips).notes(at: Date())
        #expect(notes[0].vip == true && notes[0].important)
        #expect(notes[1].vip == nil)
    }

    @Test func theDigestKeepsAddressesAndMeetingLinks() throws {
        let output = """
        {"is_error":false,"structured_output":{"headline":"h","emails":[{"id":"t1","from":"Amogh Sharma",\
        "address":"Amogh Sharma <Amogh@InsideEdge.club>","subject":"Deck","gist":"Wants the deck","urgency":"normal",\
        "needs_reply":true}],"events":[{"id":"e1","title":"Standup","start":"2026-11-04T10:00:00Z",\
        "link":"https://meet.google.com/abc-defg-hij"},{"id":"e2","title":"Lunch","start":"2026-11-04T13:00:00Z",\
        "link":"javascript:alert(1)"}],"tasks":[]}}
        """
        let digest = try #require(AgentDigest.parse(output: Data(output.utf8)))
        #expect(digest.emails[0].address == "amogh@insideedge.club")
        #expect(digest.events[0].link == "https://meet.google.com/abc-defg-hij")
        #expect(digest.events[1].link == nil)
        let notes = AgentNews(events: digest.events).notes(at: Date())
        #expect(notes[0].link == "https://meet.google.com/abc-defg-hij")
    }

    @Test func doneLeavesTheCardAndNeverComesBack() {
        var memory = AgentMemory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let digest = AgentDigest(headline: "h", emails: [email("t1", "A", nil), email("t2", "B", nil)], events: [], tasks: [])
        let news = memory.news(from: digest, now: now)
        memory.updatePending(with: news.notes(at: now), replacing: true, headline: "Two emails", now: now)
        #expect(memory.pending.count == 2)
        let first = memory.markDone(["mail:t1": now.timeIntervalSince1970])
        let again = memory.markDone(["mail:t1": now.timeIntervalSince1970])
        #expect(first)
        #expect(!again, "already done")
        #expect(memory.pending.map(\.id) == ["mail:t2"])
        #expect(memory.threadsToMarkRead == ["t1"])
        memory.markedRead["t1"] = now.timeIntervalSince1970
        #expect(memory.threadsToMarkRead.isEmpty)
        // A briefing that still sees it doesn't bring it back.
        memory.updatePending(with: AgentNews(emails: digest.emails).notes(at: now), replacing: true, headline: "h", now: now)
        #expect(memory.pending.map(\.id) == ["mail:t2"])
        memory.markDone(["mail:t2": now.timeIntervalSince1970])
        #expect(memory.pending.isEmpty && memory.pendingHeadline == nil)
        // Done before Mochi ever mentioned it (marked on the phone from a cloud card): never news.
        var fresh = AgentMemory()
        fresh.markDone(["mail:t1": now.timeIntervalSince1970])
        let freshNews = fresh.news(from: digest, now: now)
        #expect(freshNews.emails.map(\.id) == ["t2"])
    }

    @Test func doneSurvivesSavingAndOldFiles() throws {
        var memory = AgentMemory()
        memory.markDone(["mail:t1": 1_800_000_000])
        memory.markedRead["t1"] = 1_800_000_001
        let data = try JSONEncoder().encode(memory)
        let back = try JSONDecoder().decode(AgentMemory.self, from: data)
        #expect(back.done == ["mail:t1": 1_800_000_000] && back.markedRead == ["t1": 1_800_000_001])
        let old = try JSONDecoder().decode(AgentMemory.self, from: Data(#"{"seen":{}}"#.utf8))
        #expect(old.done.isEmpty)
    }

    @Test func theDoneListStaysSmallAndRecent() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var ids: [String: Double] = ["old": now.timeIntervalSince1970 - 8 * 86_400]
        for i in 0..<400 { ids["mail:\(i)"] = now.timeIntervalSince1970 - Double(i) }
        let trimmed = AgentDoneList(ids: ids).trimmed(now: now)
        #expect(trimmed.ids.count == AgentDoneList.maxItems)
        #expect(trimmed.ids["old"] == nil && trimmed.ids["mail:0"] != nil && trimmed.ids["mail:399"] == nil)
        #expect(AgentDoneList.decode(trimmed.json) == trimmed)
        #expect(AgentDoneList.decode("nope") == nil)
    }

    @Test func markingReadOnlyRemovesUnread() {
        #expect(AgentCommand.markReadArguments.last == "mcp__claude_ai_Gmail__unlabel_thread")
        #expect(!AgentCommand.markReadArguments.contains { $0.contains("send") || $0.contains("trash") || $0.contains("Bash") })
        let prompt = AgentCommand.markReadPrompt(threadIDs: ["t1", "t2"])
        #expect(prompt.contains("t1, t2") && prompt.contains("UNREAD"))
        #expect(AgentCommand.markReadSucceeded(output: Data(#"{"is_error":false,"result":"Marked 2."}"#.utf8)))
        #expect(!AgentCommand.markReadSucceeded(output: Data(#"{"is_error":true,"result":"No access"}"#.utf8)))
        #expect(!AgentCommand.markReadSucceeded(output: Data("garbage".utf8)))
    }

    @Test func settingsKeepVIPsAndTheMarkReadSwitch() throws {
        var settings = AgentSettings()
        #expect(settings.vips.isEmpty && settings.markReadWhenDone)
        settings.vips = ["Amogh"]
        settings.markReadWhenDone = false
        let back = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.vips == ["Amogh"] && !back.markReadWhenDone)
    }
}
