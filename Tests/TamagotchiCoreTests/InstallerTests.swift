import Foundation
import Testing
@testable import TamagotchiCore
import TamagotchiWire

@Suite("Ordered JSON")
struct OrderedJSONTests {
    @Test func roundTripsPreservingOrderAndNumbers() throws {
        let text = """
        {
          "zeta": 1.50,
          "alpha": [true, false, null, -0.5e10],
          "unicode": "caf\\u00e9 \\ud83d\\ude00 \\"q\\"",
          "nested": {"b": {}, "a": []}
        }
        """
        let value = try OrderedJSON.parse(text)
        #expect(value.objectValue?.keys == ["zeta", "alpha", "unicode", "nested"])
        #expect(value.objectValue?["zeta"] == .number("1.50"))
        #expect(value.objectValue?["unicode"]?.stringValue == "café 😀 \"q\"")
        let reparsed = try OrderedJSON.parse(OrderedJSON.serialize(value))
        #expect(reparsed == value)
    }

    @Test(arguments: ["{", "{\"a\": }", "[1,]", "{\"a\":1} extra", "{'a': 1}", "{\"a\": 01}", "// comment\n{}"])
    func rejectsInvalidJSON(text: String) {
        #expect(throws: JSONParseError.self) { try OrderedJSON.parse(text) }
    }

    @Test func agreesWithFoundationOnStrings() throws {
        let original = ["k": "line\nbreak\t\u{0001}/slash\\"]
        let data = try JSONSerialization.data(withJSONObject: original)
        let ours = try OrderedJSON.parse(data)
        let back = try JSONSerialization.jsonObject(with: Data(OrderedJSON.serialize(ours).utf8)) as? [String: String]
        #expect(back == original)
    }
}

@Suite("Hook installer")
struct InstallerTests {
    let helperPath: String
    let directory: URL

    init() throws {
        directory = TestSupport.temporaryDirectory("installer")
        let helper = directory.appendingPathComponent("bin/mactamagotchi-hook")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o755])
        helperPath = helper.path
    }

    func installer(_ settings: URL) -> ClaudeHookInstaller {
        ClaudeHookInstaller(settingsFile: settings, backupDirectory: directory.appendingPathComponent("Backups"), helperPath: helperPath,
                            managedSettingsFile: directory.appendingPathComponent("missing-managed.json"))
    }

    let userSettings = """
    {
      "model": "opus",
      "permissions": {"allow": ["Bash(git status)"]},
      "hooks": {
        "PreToolUse": [
          {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/guard.sh", "timeout": 30}]}
        ],
        "Stop": [
          {"hooks": [{"type": "command", "command": "say done"}]}
        ]
      },
      "statusLine": {"type": "command", "command": "~/status.sh"}
    }

    """

    @Test func installsIntoMissingFile() throws {
        let settings = directory.appendingPathComponent("fresh/settings.json")
        let result = try installer(settings).install(events: ClaudeHookEvent.allCases)
        #expect(result.changed)
        #expect(result.backup == nil)
        let value = try OrderedJSON.parse(Data(contentsOf: settings))
        let installed = HookSettingsMerger.installedCommands(in: value)
        #expect(installed.count == ClaudeHookEvent.allCases.count)
        #expect(installer(settings).inspect(events: ClaudeHookEvent.allCases).status == .installed)
    }

    @Test func preservesExistingHooksSettingsAndOrder() throws {
        let settings = directory.appendingPathComponent("existing/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try userSettings.write(to: settings, atomically: true, encoding: .utf8)
        let original = try OrderedJSON.parse(Data(contentsOf: settings))

        let result = try installer(settings).install(events: ClaudeHookEvent.allCases)
        #expect(result.backup != nil)
        #expect(try Data(contentsOf: result.backup!) == Data(userSettings.utf8))

        let updated = try OrderedJSON.parse(Data(contentsOf: settings))
        #expect(HookSettingsMerger.verifyPreserved(original: original, updated: updated).isEmpty)
        #expect(updated.objectValue?.keys == ["model", "permissions", "hooks", "statusLine"])
        let preTool = updated.objectValue?["hooks"]?.objectValue?["PreToolUse"]?.arrayValue
        #expect(preTool?.count == 2)
        #expect(preTool?.first?.objectValue?["matcher"]?.stringValue == "Bash")
        let stop = updated.objectValue?["hooks"]?.objectValue?["Stop"]?.arrayValue
        #expect(stop?.first?.objectValue?["hooks"]?.arrayValue?.first?.objectValue?["command"]?.stringValue == "say done")
        #expect(try String(contentsOf: settings, encoding: .utf8).hasSuffix("}\n"))
    }

    @Test func installIsIdempotent() throws {
        let settings = directory.appendingPathComponent("idem/settings.json")
        try installer(settings).install(events: ClaudeHookEvent.allCases)
        let first = try Data(contentsOf: settings)
        let second = try installer(settings).install(events: ClaudeHookEvent.allCases)
        #expect(second.changed == false)
        #expect(try Data(contentsOf: settings) == first)
    }

    @Test func updatesOutdatedHelperPathInPlace() throws {
        let settings = directory.appendingPathComponent("update/settings.json")
        var old = installer(settings)
        old.helperPath = "/Applications/Old.app/Contents/Helpers/mactamagotchi-hook"
        // Write an outdated install without the executable check.
        let merged = try HookSettingsMerger.merge(.object(JSONObject()), commands: old.commands(for: [.stop, .preToolUse]))
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(OrderedJSON.serialize(merged).utf8).write(to: settings)
        if case .needsUpdate = installer(settings).inspect(events: [.stop, .preToolUse]).status {} else { Issue.record("expected needsUpdate") }

        try installer(settings).install(events: [.stop, .preToolUse])
        let value = try OrderedJSON.parse(Data(contentsOf: settings))
        let commands = HookSettingsMerger.installedCommands(in: value)
        #expect(commands["Stop"]?.count == 1)
        #expect(commands["Stop"]?.first?.contains(helperPath) == true)
        #expect(installer(settings).inspect(events: [.stop, .preToolUse]).status == .installed)
    }

    @Test func uninstallRemovesOnlyOurEntries() throws {
        let settings = directory.appendingPathComponent("uninstall/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try userSettings.write(to: settings, atomically: true, encoding: .utf8)
        try installer(settings).install(events: ClaudeHookEvent.allCases)
        let result = try installer(settings).uninstall()
        #expect(result.changed)
        let after = try OrderedJSON.parse(Data(contentsOf: settings))
        let before = try OrderedJSON.parse(userSettings)
        #expect(after.semanticallyEquals(before))
        #expect(installer(settings).inspect(events: ClaudeHookEvent.allCases).status == .notInstalled)
    }

    @Test func uninstallDropsHooksKeyOnlyWhenWeEmptiedIt() throws {
        let settings = directory.appendingPathComponent("only-ours/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"model\": \"opus\"}\n".write(to: settings, atomically: true, encoding: .utf8)
        try installer(settings).install(events: [.stop])
        try installer(settings).uninstall()
        let after = try OrderedJSON.parse(Data(contentsOf: settings))
        #expect(after.objectValue?.keys == ["model"])
    }

    @Test func refusesMalformedSettingsAndLeavesThemUntouched() throws {
        let settings = directory.appendingPathComponent("broken/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = "{\n  \"model\": \"opus\",\n  // a comment\n}\n"
        try broken.write(to: settings, atomically: true, encoding: .utf8)
        #expect(throws: ClaudeHookInstaller.InstallError.self) { try installer(settings).install(events: [.stop]) }
        #expect(try String(contentsOf: settings, encoding: .utf8) == broken)
        if case .unreadable = installer(settings).inspect(events: [.stop]).status {} else { Issue.record("expected unreadable") }
    }

    @Test func refusesUnexpectedHookShapes() throws {
        let settings = directory.appendingPathComponent("shape/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"hooks\": {\"Stop\": \"not-an-array\"}}".write(to: settings, atomically: true, encoding: .utf8)
        #expect(throws: ClaudeHookInstaller.InstallError.self) { try installer(settings).install(events: [.stop]) }
    }

    @Test func followsSymlinkedSettings() throws {
        let real = directory.appendingPathComponent("dotfiles/claude-settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}\n".write(to: real, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent("home/.claude/settings.json")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try installer(link).install(events: [.stop])
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(HookSettingsMerger.installedCommands(in: try OrderedJSON.parse(Data(contentsOf: real)))["Stop"] != nil)
    }

    @Test func verificationCatchesAnyForeignChange() throws {
        let original = try OrderedJSON.parse(userSettings)
        var tampered = original.objectValue!
        tampered["model"] = .string("sonnet")
        #expect(!HookSettingsMerger.verifyPreserved(original: original, updated: .object(tampered)).isEmpty)
        var hooks = original.objectValue!["hooks"]!.objectValue!
        hooks["Stop"] = .array([])
        var droppedHook = original.objectValue!
        droppedHook["hooks"] = .object(hooks)
        #expect(!HookSettingsMerger.verifyPreserved(original: original, updated: .object(droppedHook)).isEmpty)
    }

    @Test func commandsAreQuotedAndFailSafe() {
        let command = HookSettingsMerger.command(helperPath: "/Users/me/Library/Application Support/It's Here/mactamagotchi-hook", event: .stop)
        #expect(command.hasPrefix("'/Users/me/Library/Application Support/It'\\''s Here/mactamagotchi-hook' claude-hook Stop"))
        #expect(command.hasSuffix("2>/dev/null || true"))
        #expect(HookSettingsMerger.isOurs(HookSettingsMerger.handler(command: command, event: .stop)))
        #expect(!HookSettingsMerger.isOurs(.object(JSONObject(["type": .string("command"), "command": .string("echo mactamagotchi-hook")]))))
    }

    @Test func sessionEndKeepsDefaultBudget() {
        let handler = HookSettingsMerger.handler(command: "x claude-hook SessionEnd", event: .sessionEnd)
        #expect(handler.objectValue?["timeout"] == nil)
        #expect(HookSettingsMerger.handler(command: "x", event: .stop).objectValue?["timeout"] == .number("5"))
    }

    @Test func reportsDisabledHooksAndManagedPolicies() throws {
        let settings = directory.appendingPathComponent("disabled/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"disableAllHooks\": true}".write(to: settings, atomically: true, encoding: .utf8)
        let managed = directory.appendingPathComponent("managed.json")
        try "{\"allowManagedHooksOnly\": true}".write(to: managed, atomically: true, encoding: .utf8)
        var subject = installer(settings)
        subject.managedSettingsFile = managed
        let inspection = subject.inspect(events: [.stop])
        #expect(inspection.hooksDisabled)
        #expect(inspection.managedHooksOnly)
    }

    @Test func backupsArePrunedButKept() throws {
        let settings = directory.appendingPathComponent("backups/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: settings, atomically: true, encoding: .utf8)
        var date = Date()
        for _ in 0..<25 {
            try installer(settings).install(events: [.stop], now: date)
            date += 1
            try installer(settings).uninstall(now: date)
            date += 1
        }
        #expect(installer(settings).backups().count == 20)
    }

    @Test func compatibilityFallsBackToCoreEvents() {
        let report = HookCompatibility.detect(installation: nil)
        #expect(report.method == "assumed")
        #expect(Set(report.supported) == Set(ClaudeHookEvent.allCases.filter(\.isCore)))
    }

    @Test func compatibilityScanFindsQuotedEventNames() throws {
        let fake = directory.appendingPathComponent("fake-claude.js")
        let names = ClaudeHookEvent.allCases.filter { $0 != .postToolBatch }.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        try Data(("var events=[" + names + "];" + String(repeating: " ", count: 2048)).utf8).write(to: fake)
        let report = HookCompatibility.detect(installation: ClaudeInstallation(executable: fake, resolved: fake, version: "9.9.9"))
        #expect(report.method == "inspected")
        #expect(report.unsupported == [.postToolBatch])
    }
}
