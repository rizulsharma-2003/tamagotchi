import Foundation
import Testing
@testable import TamagotchiCore
@testable import TamagotchiWire

@Suite("Claude's summaries for the iPhone")
struct SummaryTests {
    let environment = ["CLAUDE_PROJECT_DIR": "/Users/me/Projects/InsideEdge"]

    private func hook(_ object: [String: Any], summaries: Bool) -> WireEvent {
        let raw = try! JSONSerialization.data(withJSONObject: object)
        return HookPayloadSanitizer.sanitize(raw: raw, argumentEvent: nil, environment: environment, includeSummary: summaries)
    }

    private let stop: [String: Any] = [
        "session_id": "s1", "hook_event_name": "Stop", "stop_hook_active": false,
        "last_assistant_message": "Fixed the login bug.\r\n\r\n\r\n- Edited `Auth.swift`\n- Tests pass",
    ]
    private let edit: [String: Any] = [
        "session_id": "s1", "hook_event_name": "PostToolUse", "tool_name": "Edit", "tool_use_id": "t1",
        "tool_input": ["file_path": "/Users/me/Projects/InsideEdge/Sources/Auth.swift", "old_string": "secret", "new_string": "hunter2"],
    ]

    @Test func claudesWordsOnlyTravelWhenSharing() throws {
        #expect(hook(stop, summaries: false).summary == nil)
        #expect(hook(edit, summaries: false).file == nil)
        let summary = hook(stop, summaries: true).summary
        #expect(summary == "Fixed the login bug.\n\n- Edited `Auth.swift`\n- Tests pass")
        let changed = hook(edit, summaries: true)
        #expect(changed.file == "Auth.swift")
        let encoded = String(decoding: try changed.encodedLine(), as: UTF8.self)
        #expect(!encoded.contains("Sources/"))
        #expect(!encoded.contains("hunter2"))
        // Before the tool runs nothing is reported as changed.
        var before = edit
        before["hook_event_name"] = "PreToolUse"
        #expect(hook(before, summaries: true).file == nil)
    }

    @Test func summariesAreNeverKept() throws {
        let event = hook(stop, summaries: true)
        #expect(event.withoutSummary.summary == nil)
        #expect(event.withoutSummary.file == nil)
        try EventSchemaValidator.validate(event)
        var huge = event
        huge.summary = String(repeating: "a", count: HookPayloadSanitizer.maxSummaryLength + 1)
        #expect(throws: EventSchemaValidator.Rejection.self) { try EventSchemaValidator.validate(huge) }
        // The world journals normalized events, which have nowhere to keep Claude's words.
        let normalized = EventNormalizer.normalize(event)
        let journaled = String(decoding: try JSONEncoder().encode(normalized), as: UTF8.self)
        #expect(!journaled.contains("login bug"))
    }

    @Test func paragraphsKeepLineBreaks() {
        #expect(WireText.paragraphs("a\u{7}b\n\n\n\nc  d\n\n", maxLength: 100) == "ab\n\nc d")
        #expect(WireText.paragraphs("abcdef", maxLength: 4) == "abc…")
        #expect(WireText.paragraphs(" \n \n", maxLength: 10) == nil)
    }

    @Test func collectsEachTurnsFiles() {
        var reports = SessionReports()
        var prompt = WireEvent(id: "p", ts: 0, origin: .hook, event: "UserPromptSubmit", session: "s1")
        prompt.project = "InsideEdge"
        #expect(reports.record(prompt) == nil)
        for name in ["Auth.swift", "Auth.swift", "Login.swift"] {
            var edit = WireEvent(id: UUID().uuidString, ts: 0, origin: .hook, event: "PostToolUse", session: "s1")
            edit.file = name
            _ = reports.record(edit)
        }
        var other = WireEvent(id: "o", ts: 0, origin: .hook, event: "PostToolUse", session: "s2")
        other.file = "Other.swift"
        _ = reports.record(other)
        var stop = WireEvent(id: "x", ts: 0, origin: .hook, event: "Stop", session: "s1")
        stop.project = "InsideEdge"
        stop.summary = "Done."
        let report = reports.record(stop)
        #expect(report?.files == ["Auth.swift", "Login.swift"])
        #expect(report?.message == "Done.")
        #expect(report?.project == "InsideEdge")
        // The next turn starts empty, and simulated events never count.
        #expect(reports.record(stop)?.files == [])
        var simulated = stop
        simulated.origin = .simulator
        #expect(reports.record(simulated) == nil)
    }

    @Test func readsTheSummarizersNote() {
        let note = TurnSummarizer.parse(#"{"done":"Fixed login.","session":"Auth work","next":["Run the tests","Ship it","Extra"]}"#)
        #expect(note == TurnSummary(done: "Fixed login.", session: "Auth work", next: ["Run the tests", "Ship it"]))
        let fenced = TurnSummarizer.parse("Here you go:\n```json\n{\"done\": \"Added a test.\"}\n```")
        #expect(fenced?.done == "Added a test.")
        #expect(fenced?.next == [])
        #expect(TurnSummarizer.parse("no json here") == nil)
        #expect(TurnSummarizer.parse(#"{"session":"x"}"#) == nil)
        let output = Data(#"{"type":"result","subtype":"success","is_error":false,"result":"{\"done\":\"ok\"}"}"#.utf8)
        #expect(TurnSummarizer.result(fromOutput: output) == #"{"done":"ok"}"#)
        #expect(TurnSummarizer.result(fromOutput: Data(#"{"is_error":true,"result":"nope"}"#.utf8)) == nil)
    }

    @Test func summarizesWithoutTheModel() {
        let message = """
        ## Done

        Fixed the **login** bug in [Auth](https://example.com) and added `testLogin`.
        ```swift
        let secret = 1
        ```
        - Tests pass
        | a | b |
        """
        #expect(TurnSummarizer.plainText(message) == "Done. Fixed the login bug in Auth and added testLogin. Tests pass.")
        let report = TurnReport(sessionID: "s", project: "P", message: message, files: [], at: Date())
        #expect(TurnSummarizer.fallback(report).done == "Done. Fixed the login bug in Auth and added testLogin. Tests pass.")
        let long = TurnReport(sessionID: "s", project: "P", message: String(repeating: "Word ", count: 10) + "end. " + String(repeating: "More ", count: 40),
                              files: [], at: Date())
        #expect(TurnSummarizer.fallback(long).done == String(repeating: "Word ", count: 10) + "end.")
        let quiet = TurnReport(sessionID: "s", project: "P", message: nil, files: ["A.swift", "B.swift", "C.swift", "D.swift"], at: Date())
        #expect(TurnSummarizer.fallback(quiet).done == "Changed A.swift, B.swift, C.swift and 1 more.")
        #expect(TurnSummarizer.prompt(for: quiet, earlier: ["one", "two", "three", "four"]).contains("- two\n- three\n- four"))
    }

    @Test func sharesSessionsAndNotifications() throws {
        let card = PhoneSessionCard(id: "s1", project: "InsideEdge", phase: "done", summary: TurnSummary(done: "Fixed login."),
                                    files: ["Auth.swift"], finishedAt: 100)
        let sessions = PhoneSessions(enabled: true, sessions: [card])
        #expect(PhoneSessions.decode(sessions.json) == sessions)
        #expect(PhoneSessions.decode("{}") == nil)
        let data = PhoneAlertPayload.turnFinished(card)
        let push = AnyJSON.parse(data)
        #expect(push?["aps"]?["category"]?.stringValue == PhoneAlertPayload.turnCategory)
        #expect(push?["aps"]?["thread-id"]?.stringValue == "s1")
        #expect(push?["aps"]?["alert"]?["title"]?.stringValue == "InsideEdge")
        #expect(push?["aps"]?["alert"]?["body"]?.stringValue == "Fixed login.")
        #expect(push?["session"]?.stringValue == "s1")
        #expect(data.count < 4096)
        // The phone reads the card straight from the notification.
        let info = try JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any] ?? [:]
        #expect(PhoneSessionCard.decode(notification: info) == card)
        // Settings saved before summaries existed keep them off.
        let old = try JSONDecoder().decode(PhoneSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(!old.shareSummaries)
        #expect(!old.notifyOnlyWhenAway)
    }

    @Test func notificationCardsFoldIntoTheList() {
        let listed = PhoneSessionCard(id: "s1", project: "P", phase: "working", summary: TurnSummary(done: "Old."), files: ["A.swift"],
                                      finishedAt: 100, phaseSince: 150)
        let pushed = PhoneSessionCard(id: "s1", project: "P", phase: "done", summary: TurnSummary(done: "New."), files: ["B.swift"],
                                      finishedAt: 200)
        let merged = listed.merging(pushed)
        #expect(merged.summary?.done == "New." && merged.files == ["B.swift"] && merged.phase == "done")
        // An older finish changes nothing, and a turn that started after the finish keeps its phase.
        #expect(merged.merging(listed) == merged)
        let busy = PhoneSessionCard(id: "s1", project: "P", phase: "working", finishedAt: 100, phaseSince: 300)
        let stillBusy = busy.merging(pushed)
        #expect(stillBusy.phase == "working" && stillBusy.summary?.done == "New.")
    }

    @Test func repliesKeepTheUsersWords() {
        let request = BrainLaunch.directRequest("Run the tests", project: "InsideEdge")
        #expect(request.contains("InsideEdge"))
        #expect(request.hasSuffix("Run the tests"))
        #expect(BrainLaunch.keepsWords("From the user, via Mochi: run the tests!", of: "Run the tests"))
        #expect(!BrainLaunch.keepsWords("From the user, via Mochi: please run all tests", of: "Run the tests"))
        #expect(!BrainLaunch.keepsWords("anything", of: "  "))
    }
}
