import Foundation
import Testing
@testable import TamagotchiCore
@testable import TamagotchiWire

@Suite("Hook payload sanitizer")
struct SanitizerTests {
    let environment = ["CLAUDE_PROJECT_DIR": "/Users/me/Projects/InsideEdge"]

    func payload(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func dropsPromptsToolInputsAndOutputs() throws {
        let raw = payload([
            "session_id": "abc-123",
            "transcript_path": "/Users/me/.claude/projects/x/abc.jsonl",
            "cwd": "/Users/me/Projects/InsideEdge/Sources",
            "hook_event_name": "PostToolUse",
            "tool_name": "Write",
            "tool_use_id": "toolu_01",
            "tool_input": ["file_path": "/Users/me/secret.txt", "content": "API_KEY=hunter2"],
            "tool_response": ["success": true, "output": "TOKEN"],
            "prompt": "please use my password hunter2",
        ])
        let event = HookPayloadSanitizer.sanitize(raw: raw, argumentEvent: nil, environment: environment)
        let encoded = String(decoding: try event.encodedLine(), as: UTF8.self)
        #expect(!encoded.contains("hunter2"))
        #expect(!encoded.contains("secret.txt"))
        #expect(!encoded.contains("TOKEN"))
        #expect(!encoded.contains("transcript"))
        #expect(event.event == "PostToolUse")
        #expect(event.tool == "Write")
        #expect(event.toolCategory == "edit")
        #expect(event.session == "abc-123")
        // Project identity comes from CLAUDE_PROJECT_DIR, not the (sub)directory cwd.
        #expect(event.project == "InsideEdge")
        #expect(event.projectKey == ProjectIdentity.key(forPath: "/Users/me/Projects/InsideEdge"))
    }

    @Test func keepsOnlyExitCodeFromFailures() {
        let raw = payload([
            "session_id": "s", "hook_event_name": "PostToolUseFailure", "tool_name": "Bash",
            "tool_input": ["command": "npm test"],
            "error": "Exit code 1\nFAIL src/app.test.js\n  secret stack trace",
        ])
        let event = HookPayloadSanitizer.sanitize(raw: raw, argumentEvent: nil, environment: [:])
        #expect(event.exitCode == 1)
        #expect(event.commandKind == "test")
        #expect(event.commandReliable == true)
        #expect(event.message == nil)
    }

    @Test func notificationKeepsTypeAndShortMessage() {
        let long = String(repeating: "x", count: 500)
        let raw = payload(["session_id": "s", "hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "Needs permission \n\n" + long])
        let event = HookPayloadSanitizer.sanitize(raw: raw, argumentEvent: nil, environment: [:])
        #expect(event.notificationType == "permission_prompt")
        #expect((event.message?.count ?? 0) <= 160)
        #expect(event.message?.contains("\n") == false)
    }

    @Test func stopFailureKeepsErrorTypeOnly() {
        let raw = payload(["session_id": "s", "hook_event_name": "StopFailure", "error": "rate_limit", "error_details": "429 Too Many Requests",
                           "last_assistant_message": "API Error: Rate limit reached"])
        let event = HookPayloadSanitizer.sanitize(raw: raw, argumentEvent: nil, environment: [:])
        #expect(event.reason == "rate_limit")
        let encoded = String(decoding: try! event.encodedLine(), as: UTF8.self)
        #expect(!encoded.contains("429"))
        #expect(!encoded.contains("API Error"))
    }

    @Test func malformedPayloadFallsBackToArgument() {
        let event = HookPayloadSanitizer.sanitize(raw: Data("not json {".utf8), argumentEvent: "Stop", environment: [:])
        #expect(event.event == "Stop")
        #expect(event.origin == .hook)
    }

    @Test func oversizedPayloadUsesBoundedHeadScan() {
        var text = "{\"session_id\": \"big-1\", \"hook_event_name\": \"PreToolUse\", \"tool_name\": \"Write\", \"tool_input\": {\"content\": \""
        text += String(repeating: "a", count: HookPayloadSanitizer.maxParsedBytes + 10)
        text += "\"}}"
        let event = HookPayloadSanitizer.sanitize(raw: Data(text.utf8), argumentEvent: nil, environment: [:])
        #expect(event.event == "PreToolUse")
        #expect(event.session == "big-1")
        #expect(event.tool == "Write")
    }

    @Test func identicalPayloadsShareAnID() {
        let raw = payload(["session_id": "s", "hook_event_name": "Stop", "prompt_id": "p1"])
        let a = HookPayloadSanitizer.sanitize(raw: raw, argumentEvent: nil, environment: [:])
        let b = HookPayloadSanitizer.sanitize(raw: raw, argumentEvent: nil, environment: [:])
        #expect(a.id == b.id)
    }

    @Test func subagentContextIsFlagged() {
        let raw = payload(["session_id": "s", "hook_event_name": "PreToolUse", "tool_name": "Read", "agent_id": "agent-7", "agent_type": "Explore"])
        let event = HookPayloadSanitizer.sanitize(raw: raw, argumentEvent: nil, environment: [:])
        #expect(event.inSubagent == true)
    }
}

@Suite("Command classifier")
struct CommandClassifierTests {
    @Test(arguments: [
        ("swift test", "test", true),
        ("swift build -c release", "build", true),
        ("cd app && npm test", "test", true),
        ("npm run test:unit", "test", true),
        ("xcodebuild -scheme App test", "test", true),
        ("FOO=1 pytest -q", "test", true),
        ("cargo build && cargo test", "test", true),
        ("swift test 2>&1 | tail -20", "test", false),
        ("npm test || true", "test", false),
        ("go test ./...; echo done", "test", false),
        ("make", "build", true),
        ("./gradlew assembleDebug", "build", true),
    ])
    func recognizes(command: String, kind: String, reliable: Bool) {
        let result = CommandClassifier.classify(command)
        #expect(result.kind == kind)
        #expect(result.reliable == reliable)
    }

    @Test(arguments: ["ls -la", "git status", "echo 'swift test'", "cat test.txt", "rm -rf build"])
    func ignoresOtherCommands(command: String) {
        #expect(CommandClassifier.classify(command).kind == nil)
    }

    @Test func backgroundRunsAreNotReliable() {
        let raw = try! JSONSerialization.data(withJSONObject: [
            "session_id": "s", "hook_event_name": "PostToolUse", "tool_name": "Bash",
            "tool_input": ["command": "swift test", "run_in_background": true],
        ])
        let event = HookPayloadSanitizer.sanitize(raw: raw, argumentEvent: nil, environment: [:])
        #expect(event.commandKind == "test")
        #expect(event.commandReliable == false)
        #expect(event.backgrounded == true)
    }
}

@Suite("Event schema validation")
struct ValidatorTests {
    @Test func acceptsWellFormedEvent() throws {
        let line = try TestSupport.wire("PreToolUse", tool: "Read").encodedLine()
        let event = try EventSchemaValidator.decode(line)
        #expect(event.event == "PreToolUse")
    }

    @Test func rejectsOversizedLines() {
        let line = Data(repeating: 0x41, count: EventSchemaValidator.maxLineBytes + 1)
        #expect(throws: EventSchemaValidator.Rejection.self) { try EventSchemaValidator.decode(line) }
    }

    @Test func rejectsMalformedJSON() {
        #expect(throws: EventSchemaValidator.Rejection.self) { try EventSchemaValidator.decode(Data("{nope".utf8)) }
        #expect(throws: EventSchemaValidator.Rejection.self) { try EventSchemaValidator.decode(Data("{\"v\":1}".utf8)) }
    }

    @Test func rejectsNewerSchemaVersions() throws {
        var wire = TestSupport.wire("Stop")
        wire.v = 99
        #expect(throws: EventSchemaValidator.Rejection.unsupportedVersion(99)) { try EventSchemaValidator.decode(try wire.encodedLine()) }
    }

    @Test func rejectsInjectedIdentifiers() throws {
        var wire = TestSupport.wire("Stop")
        wire.session = "../../etc/passwd"
        #expect(throws: EventSchemaValidator.Rejection.invalidField("session")) { try EventSchemaValidator.decode(try wire.encodedLine()) }
    }

    @Test func rejectsImplausibleTimestamps() throws {
        let wire = TestSupport.wire("Stop", at: Date().addingTimeInterval(3600))
        #expect(throws: EventSchemaValidator.Rejection.implausibleTimestamp) { try EventSchemaValidator.decode(try wire.encodedLine()) }
    }

    @Test func missingOptionalFieldsAreFine() throws {
        let line = Data("{\"v\":1,\"id\":\"abc\",\"ts\":\(Date().timeIntervalSince1970),\"origin\":\"hook\",\"event\":\"Stop\"}".utf8)
        let wire = try EventSchemaValidator.decode(line)
        let event = EventNormalizer.normalize(wire)
        #expect(event.kind == .turnCompleted)
        #expect(event.sessionID == nil)
        #expect(event.project == nil)
    }

    @Test func unknownEventNamesBecomeUnknownKind() throws {
        let wire = TestSupport.wire("SomeFutureEvent")
        let event = EventNormalizer.normalize(try EventSchemaValidator.decode(try wire.encodedLine()))
        #expect(event.kind == .unknown)
    }

    @Test func reportsMustBeWellFormed() throws {
        var wire = TestSupport.wire("Report", origin: .report)
        wire.report = WireReport(kind: "deploy", status: "passed")
        #expect(throws: EventSchemaValidator.Rejection.invalidField("report")) { try EventSchemaValidator.decode(try wire.encodedLine()) }
    }
}

@Suite("Normalizer semantics")
struct NormalizerTests {
    @Test func distinctKindsForDistinctStates() {
        #expect(TestSupport.event("SessionStart").kind == .sessionStarted)
        #expect(TestSupport.event("UserPromptSubmit").kind == .promptSubmitted)
        #expect(TestSupport.event("PreToolUse", tool: "Bash").kind == .toolStarting)
        #expect(TestSupport.event("PostToolUse", tool: "Bash").kind == .toolSucceeded)
        #expect(TestSupport.event("PostToolUseFailure", tool: "Bash").kind == .toolFailed)
        #expect(TestSupport.event("PermissionRequest", tool: "Bash").kind == .permissionRequested)
        #expect(TestSupport.event("Stop").kind == .turnCompleted)
        #expect(TestSupport.event("StopFailure").kind == .turnFailed)
        #expect(TestSupport.event("SessionEnd").kind == .sessionEnded)
    }

    @Test func notificationTypesMapToAttentionOrInfo() {
        #expect(TestSupport.event("Notification") { $0.notificationType = "permission_prompt" }.kind == .attentionNeeded)
        #expect(TestSupport.event("Notification") { $0.notificationType = "idle_prompt" }.attention == .input)
        #expect(TestSupport.event("Notification") { $0.notificationType = "auth_success" }.kind == .notification)
    }

    @Test func toolSuccessIsNeverDescribedAsCompletion() {
        let event = TestSupport.event("PostToolUse", tool: "Bash")
        #expect(event.summary == "Bash finished")
        #expect(event.buildTestOutcome == nil)
    }

    @Test func turnCompletionMakesNoBuildClaims() {
        let event = TestSupport.event("Stop")
        #expect(event.summary == "Claude finished responding")
        #expect(event.buildTestOutcome == nil)
    }

    @Test func onlyReliableCommandsProduceOutcomes() {
        let reliable = TestSupport.event("PostToolUse", tool: "Bash") { $0.commandKind = "test"; $0.commandReliable = true }
        let piped = TestSupport.event("PostToolUse", tool: "Bash") { $0.commandKind = "test"; $0.commandReliable = false }
        #expect(reliable.buildTestOutcome?.passed == true)
        #expect(reliable.confidence == .derived)
        #expect(piped.buildTestOutcome == nil)
    }
}
