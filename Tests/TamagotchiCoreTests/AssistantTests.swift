import Foundation
import Testing
@testable import TamagotchiCore
import TamagotchiWire

@Suite("Ask Mochi: quick commands")
struct QuickCommandTests {
    let context = QuickCommandContext(installedApps: ["Slack", "Visual Studio Code", "Google Chrome", "Safari", "Music", "System Settings"],
                                      runningApps: ["Slack", "Visual Studio Code", "Safari"])

    @Test func musicAndVolume() {
        #expect(QuickCommands.parse("Pause the music", context: context) == .media(.playPause))
        #expect(QuickCommands.parse("hey Mochi, next song please!", context: context) == .media(.next))
        #expect(QuickCommands.parse("Motchi previous track", context: context) == .media(.previous))
        #expect(QuickCommands.parse("set the volume to 30%", context: context) == .volume(.set(30)))
        #expect(QuickCommands.parse("volume 250", context: context) == .volume(.set(100)))
        #expect(QuickCommands.parse("turn it down", context: context) == .volume(.down))
        #expect(QuickCommands.parse("Mute", context: context) == .volume(.mute))
    }

    @Test func focusAndMochiTricks() {
        #expect(QuickCommands.parse("start a 25 minute focus session", context: context) == .focus(minutes: 25))
        #expect(QuickCommands.parse("focus for 45 minutes", context: context) == .focus(minutes: 45))
        #expect(QuickCommands.parse("start focus", context: context) == .focus(minutes: nil))
        #expect(QuickCommands.parse("stop the timer", context: context) == .stopFocus)
        #expect(QuickCommands.parse("Mochi, go explore", context: context) == .explore)
        #expect(QuickCommands.parse("come home now", context: context) == .comeHome)
        #expect(QuickCommands.parse("have a snack", context: context) == .interact(.treat))
        #expect(QuickCommands.parse("what are my claudes doing?", context: context) == .sessionsStatus)
        #expect(QuickCommands.parse("What's Claude doing", context: context) == .sessionsStatus)
        #expect(QuickCommands.parse("today's recap", context: context) == .recap)
    }

    @Test func appsAndSites() {
        #expect(QuickCommands.parse("open slack", context: context) == .openApp("Slack"))
        #expect(QuickCommands.parse("open vs code", context: context) == .openApp("Visual Studio Code"))
        #expect(QuickCommands.parse("launch the chrome app", context: context) == .openApp("Google Chrome"))
        #expect(QuickCommands.parse("go to my Slack window", context: context) == .switchToApp("Slack"))
        #expect(QuickCommands.parse("switch to music", context: context) == .openApp("Music"))
        #expect(QuickCommands.parse("open youtube", context: context) == .openSite(URL(string: "https://www.youtube.com")!))
        #expect(QuickCommands.parse("open example.org", context: context) == .openSite(URL(string: "https://example.org")!))
    }

    @Test func anythingUnsureGoesToClaude() {
        for text in ["open youtube and play lofi beats", "tell the tamagotchi claude to make the animations smoother",
                     "go to the vs code mac tamagotchi window", "play the new MKBHD video", "stop", "open the report I was editing",
                     "", "   ", "Mochi"] {
            #expect(QuickCommands.parse(text, context: context) == nil, "\(text)")
        }
    }

    @Test func normalizationStripsWakeWordsAndPoliteness() {
        #expect(QuickCommands.normalize("Hey Mochi, could you please pause the music, thanks!") == "pause the music")
        #expect(QuickCommands.normalize("  Motchi —  NEXT   song.  ") == "next song")
    }
}

@Suite("Ask Mochi: tool server protocol")
struct MCPServerTests {
    let core = MCPServerCore(name: "mochi", version: "1", instructions: "hi", tools: [
        MCPToolSpec(name: "open_url", description: "Open", properties: ["url": ("string", "URL")], required: ["url"]),
    ])

    private func reply(_ outcome: MCPServerCore.Outcome) -> AnyJSON? {
        guard case .reply(let data) = outcome else { return nil }
        #expect(data.last == 0x0A)
        return AnyJSON.parse(data)
    }

    @Test func handshakeNegotiatesAVersionItSpeaks() {
        let known = reply(core.handle(Data(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#.utf8)))
        #expect(known?["result"]?["protocolVersion"]?.stringValue == "2025-11-25")
        #expect(known?["result"]?["serverInfo"]?["name"]?.stringValue == "mochi")
        #expect(known?["result"]?["capabilities"]?["tools"] != nil)
        let future = reply(core.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#.utf8)))
        #expect(future?["result"]?["protocolVersion"]?.stringValue == MCPServerCore.fallbackVersion)
    }

    @Test func listsAndCallsTools() {
        let list = reply(core.handle(Data(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#.utf8)))
        guard case .array(let tools)? = list?["result"]?["tools"] else { Issue.record("no tools"); return }
        #expect(tools.first?["name"]?.stringValue == "open_url")
        #expect(tools.first?["inputSchema"]?["required"] == ["url"])
        let call = core.handle(Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"open_url","arguments":{"url":"https://x.com"}}}"#.utf8))
        #expect(call == .call(id: .number(7), name: "open_url", arguments: ["url": "https://x.com"]))
        let unknown = reply(core.handle(Data(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"rm_rf"}}"#.utf8)))
        #expect(unknown?["result"]?["isError"]?.boolValue == true)
    }

    @Test func notificationsAndUnknownMethods() {
        #expect(core.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == .ignore)
        let probe = reply(core.handle(Data(#"{"jsonrpc":"2.0","id":"p","method":"server/discover"}"#.utf8)))
        #expect(probe?["error"]?["code"]?.numberValue == -32601)
        let garbage = reply(core.handle(Data("not json".utf8)))
        #expect(garbage?["error"]?["code"]?.numberValue == -32700)
    }

    @Test func toolResultShape() {
        let result = AnyJSON.parse(MCPServerCore.toolResult(id: "x", text: "done", isError: false))
        #expect(result?["id"]?.stringValue == "x")
        #expect(result?["result"]?["content"] == [["type": "text", "text": "done"]])
    }
}

@Suite("Ask Mochi: helper Claude session")
struct BrainTests {
    @Test func launchIsLockedDown() {
        let launch = BrainLaunch(executable: "/x/claude", model: "haiku", mcpConfigPath: "/tmp/m.json", workingDirectory: "/tmp/a")
        let args = launch.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        #expect(value("--setting-sources") == "project")
        #expect(value("--tools") == "ListAgents,SendMessage,WebSearch")
        #expect(value("--permission-prompt-tool") == "mcp__mochi__approve")
        #expect(value("--name") == "mochi")
        #expect(value("--input-format") == "stream-json")
        #expect(args.contains("--strict-mcp-config"))
        #expect(args.contains("--no-session-persistence"))
        #expect(!args.contains("--dangerously-skip-permissions"))
        let settings = AnyJSON.parse(Data(BrainLaunch.settingsJSON.utf8))
        #expect(settings?["permissions"]?["ask"] == ["SendMessage"])
    }

    @Test func mcpConfigUsesTheHelperRelay() {
        let config = BrainLaunch.mcpConfig(helper: "/h/mactamagotchi-hook", socket: "/s/paws.sock", token: "abc")
        let server = config["mcpServers"]?["mochi"]
        #expect(server?["command"]?.stringValue == "/h/mactamagotchi-hook")
        #expect(server?["args"] == ["paws"])
        #expect(server?["env"]?["MACTAMAGOTCHI_PAWS_TOKEN"]?.stringValue == "abc")
    }

    @Test func inputLineIsAStreamJSONUserMessage() {
        let line = BrainLaunch.inputLine("hi")
        #expect(line.last == 0x0A)
        let message = AnyJSON.parse(line)
        #expect(message?["type"]?.stringValue == "user")
        #expect(message?["message"]?["content"]?.stringValue == "hi")
    }

    @Test func contextNamesOnlyAppsAndProjects() {
        let context = BrainContext(time: "Thu 10:42", frontApp: "Safari", sessions: [
            .init(project: "mac-Tamagotchi", host: "Visual Studio Code", state: "working (6 min)"),
            .init(project: "website", host: nil, state: "waiting for you"),
        ])
        let text = BrainLaunch.message(request: "tell the tamagotchi claude hi", context: context)
        #expect(text.hasPrefix("[Context] Time Thu 10:42. Front app: Safari."))
        #expect(text.contains("mac-Tamagotchi (Visual Studio Code) — working (6 min); website — waiting for you."))
        #expect(text.hasSuffix("[Request] tell the tamagotchi claude hi"))
        #expect(BrainContext(time: "t", frontApp: nil, sessions: []).summary.contains("no Claude sessions"))
        #expect(BrainLaunch.message(request: "hi", context: context, spoken: true).contains("[Request, spoken: names may be misheard] hi"))
    }

    @Test func parsesTheEventStream() {
        let initLine = #"{"type":"system","subtype":"init","model":"claude-haiku-5-5","mcp_servers":[{"name":"mochi","status":"connected"}]}"#
        #expect(BrainEvent.parse(Data(initLine.utf8)) == [.started(model: "claude-haiku-5-5", toolsConnected: true)])
        let assistant = #"{"type":"assistant","message":{"content":[{"type":"text","text":"On it"},{"type":"tool_use","id":"t1","name":"SendMessage","input":{"to":"mac-tamagotchi-bb [856803]","message":"hi"}}]}}"#
        let events = BrainEvent.parse(Data(assistant.utf8))
        #expect(events.count == 2)
        #expect(events.first == .text("On it"))
        let result = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,"content":[{"type":"text","text":"sent"}]}]}}"#
        #expect(BrainEvent.parse(Data(result.utf8)) == [.toolResult(id: "t1", isError: false, text: "sent")])
        let done = #"{"type":"result","subtype":"success","is_error":false,"result":"Sent!","duration_ms":3651}"#
        #expect(BrainEvent.parse(Data(done.utf8)) == [.finished(result: "Sent!", isError: false, durationMs: 3651)])
        let failed = #"{"type":"result","subtype":"error_max_turns","is_error":false}"#
        #expect(BrainEvent.parse(Data(failed.utf8)) == [.finished(result: nil, isError: true, durationMs: nil)])
        #expect(BrainEvent.parse(Data(#"{"type":"rate_limit_event"}"#.utf8)).isEmpty)
        #expect(BrainEvent.parse(Data("garbage".utf8)).isEmpty)
    }

    @Test func describesSteps() {
        #expect(BrainStep.describe(tool: "SendMessage", input: ["to": "mac-tamagotchi-bb [856803]"])?.text == "Asking to send to mac-tamagotchi-bb")
        #expect(BrainStep.describe(tool: "mcp__mochi__open_url", input: ["url": "https://www.youtube.com/watch?v=1"])?.text == "Opening www.youtube.com")
        #expect(BrainStep.describe(tool: "mcp__mochi__approve", input: [:]) == nil)
    }

    @Test func matchesSessionNamesToProjects() {
        let tamagotchi = ProjectRef(displayName: "mac-Tamagotchi", key: "k1", path: "/p/mac-Tamagotchi")
        let alumni = ProjectRef(displayName: "alumni_connect_flutter", key: "k2")
        let mac = ProjectRef(displayName: "mac", key: "k3")
        let projects = [mac, tamagotchi, alumni]
        #expect(AgentNames.display("mac-tamagotchi-bb [856803]") == "mac-tamagotchi-bb")
        #expect(AgentNames.display("@tamatest") == "tamatest")
        #expect(AgentNames.project(forAgent: "mac-tamagotchi-bb [856803]", among: projects) == tamagotchi)
        #expect(AgentNames.project(forAgent: "alumni-connect-flutter-f8", among: projects) == alumni)
        #expect(AgentNames.project(forAgent: "rizzfolio-2f", among: projects) == nil)
        #expect(AgentNames.project(forAgent: "The user opened the file", among: projects) == nil)
    }
}

@Suite("Ask Mochi: settings and wire")
struct AssistantSettingsTests {
    @Test func decodesOldAndPartialSettings() {
        let old = AppSettings.decodeTolerantly(Data(#"{"petName":"Mochi"}"#.utf8))
        #expect(old.assistant == AssistantSettings())
        let partial = AppSettings.decodeTolerantly(Data(#"{"assistant":{"shortcut":"controlOptionM","bogus":1}}"#.utf8))
        #expect(partial.assistant.shortcut == .controlOptionM)
        #expect(partial.assistant.enabled)
        #expect(partial.assistant.confirmBeforeSending)
    }

    @Test func hookCarriesTheHostAppOnly() throws {
        let raw = Data(#"{"hook_event_name":"Stop","session_id":"s1","cwd":"/Users/me/mac-Tamagotchi"}"#.utf8)
        let event = HookPayloadSanitizer.sanitize(raw: raw, argumentEvent: nil,
                                                  environment: ["__CFBundleIdentifier": "com.microsoft.VSCode"])
        #expect(event.host == "com.microsoft.VSCode")
        let odd = HookPayloadSanitizer.sanitize(raw: raw, argumentEvent: nil, environment: ["__CFBundleIdentifier": "bad id; rm -rf"])
        #expect(odd.host == nil)
        let decoded = try EventSchemaValidator.decode(try event.encodedLine())
        let companion = EventNormalizer.normalize(decoded)
        #expect(companion.metadata["host"] == "com.microsoft.VSCode")
        var registry = SessionRegistry()
        _ = registry.apply(companion)
        #expect(registry.all.first?.hostApp == "com.microsoft.VSCode")
    }

    @Test func pawsSocketIsSeparateFromTheBridge() {
        let paths = BridgePaths(home: URL(fileURLWithPath: "/tmp/mt-test-home"))
        #expect(paths.pawsSocketFile.lastPathComponent == "paws.sock")
        #expect(paths.socketFile.lastPathComponent == "bridge.sock")
        let long = BridgePaths(home: URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 120)))
        #expect(long.pawsSocketFile.path.utf8.count <= BridgePaths.maxSocketPathBytes)
        #expect(long.pawsSocketFile != long.socketFile)
    }
}
