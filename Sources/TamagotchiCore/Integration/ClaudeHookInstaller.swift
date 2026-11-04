import Darwin
import Foundation
import TamagotchiWire

/// Pure functions that add or remove MacTamagotchi's hook entries in a Claude
/// Code settings document without disturbing anything else.
public enum HookSettingsMerger {
    public enum MergeError: Error, Equatable, CustomStringConvertible {
        case rootNotObject
        case hooksNotObject
        case eventNotArray(String)
        case preservationFailed([String])

        public var description: String {
            switch self {
            case .rootNotObject: return "settings.json does not contain a JSON object"
            case .hooksNotObject: return "the \"hooks\" setting is not an object"
            case .eventNotArray(let event): return "hooks.\(event) is not an array"
            case .preservationFailed(let problems): return "safety check failed: " + problems.joined(separator: "; ")
            }
        }
    }

    /// True for a hook handler that MacTamagotchi installed.
    public static func isOurs(_ handler: JSONValue) -> Bool {
        guard let command = handler.objectValue?["command"]?.stringValue else { return false }
        return command.contains(HelperInfo.executableName) && command.contains(" \(HelperInfo.hookSubcommand)")
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The command written into settings. It exits 0 even if the helper has been
    /// deleted, so a removed app can never make Claude Code report hook errors.
    public static func command(helperPath: String, event: ClaudeHookEvent, environment: [String: String] = [:]) -> String {
        let assignments = environment.keys.sorted().map { "\($0)=\(shellQuote(environment[$0]!))" }
        let prefix = assignments.isEmpty ? "" : assignments.joined(separator: " ") + " "
        return "\(prefix)\(shellQuote(helperPath)) \(HelperInfo.hookSubcommand) \(event.rawValue) 2>/dev/null || true"
    }

    public static func handler(command: String, event: ClaudeHookEvent) -> JSONValue {
        var object = JSONObject([
            "type": .string("command"),
            "command": .string(command),
        ])
        if let timeout = event.hookTimeoutSeconds {
            object["timeout"] = .number(String(timeout))
        }
        return .object(object)
    }

    /// Event name → our installed command(s).
    public static func installedCommands(in root: JSONValue) -> [String: [String]] {
        guard let hooks = root.objectValue?["hooks"]?.objectValue else { return [:] }
        var result: [String: [String]] = [:]
        for member in hooks.members {
            for group in member.value.arrayValue ?? [] {
                for handler in group.objectValue?["hooks"]?.arrayValue ?? [] where isOurs(handler) {
                    if let command = handler.objectValue?["command"]?.stringValue {
                        result[member.key, default: []].append(command)
                    }
                }
            }
        }
        return result
    }

    /// Adds or updates our handler for each event in `commands`, and removes our
    /// handlers from any other event.
    public static func merge(_ root: JSONValue, commands: [ClaudeHookEvent: String]) throws -> JSONValue {
        guard var object = root.objectValue else { throw MergeError.rootNotObject }
        var hooks: JSONObject
        switch object["hooks"] {
        case nil: hooks = JSONObject()
        case .object(let existing)?: hooks = existing
        default: throw MergeError.hooksNotObject
        }

        // Remove ours everywhere first (handles moved, duplicated or outdated entries),
        // keeping the position of event keys we are about to write again…
        hooks = strip(hooks, keepingKeys: Set(commands.keys.map(\.rawValue)))
        // …then add exactly one fresh handler per requested event.
        for event in ClaudeHookEvent.allCases {
            guard let command = commands[event] else { continue }
            var groups: [JSONValue]
            switch hooks[event.rawValue] {
            case nil: groups = []
            case .array(let existing)?: groups = existing
            default: throw MergeError.eventNotArray(event.rawValue)
            }
            groups.append(.object(JSONObject(["hooks": .array([handler(command: command, event: event)])])))
            hooks[event.rawValue] = .array(groups)
        }
        object["hooks"] = .object(hooks)
        let merged = JSONValue.object(object)
        let problems = verifyPreserved(original: root, updated: merged)
        guard problems.isEmpty else { throw MergeError.preservationFailed(problems) }
        return merged
    }

    /// Removes every handler we installed. Groups and event keys that become empty
    /// *because of that removal* are dropped; nothing else is touched.
    public static func removeOurs(_ root: JSONValue) throws -> JSONValue {
        guard var object = root.objectValue else { throw MergeError.rootNotObject }
        guard let existing = object["hooks"] else { return root }
        guard case .object(let hooks) = existing else { throw MergeError.hooksNotObject }
        let stripped = strip(hooks, keepingKeys: [])
        if stripped.members.isEmpty, !hooks.members.isEmpty {
            object["hooks"] = nil
        } else {
            object["hooks"] = .object(stripped)
        }
        let updated = JSONValue.object(object)
        let problems = verifyPreserved(original: root, updated: updated)
        guard problems.isEmpty else { throw MergeError.preservationFailed(problems) }
        return updated
    }

    private static func strip(_ hooks: JSONObject, keepingKeys: Set<String>) -> JSONObject {
        var result = JSONObject()
        for member in hooks.members {
            guard case .array(let groups) = member.value else {
                // Not ours to judge; keep as-is unless it is an event we must write.
                result.members.append(member)
                continue
            }
            var keptGroups: [JSONValue] = []
            var removedAny = false
            for group in groups {
                guard var groupObject = group.objectValue,
                      case .array(let handlers)? = groupObject["hooks"] else {
                    keptGroups.append(group)
                    continue
                }
                let kept = handlers.filter { !isOurs($0) }
                if kept.count == handlers.count {
                    keptGroups.append(group)
                } else {
                    removedAny = true
                    if !kept.isEmpty {
                        groupObject["hooks"] = .array(kept)
                        keptGroups.append(.object(groupObject))
                    }
                }
            }
            if keptGroups.isEmpty, removedAny, !keepingKeys.contains(member.key) { continue }
            result.members.append(.init(key: member.key, value: .array(keptGroups)))
        }
        return result
    }

    /// Checks that every setting and every non-MacTamagotchi hook in `original`
    /// survives unchanged (and in order) in `updated`.
    public static func verifyPreserved(original: JSONValue, updated: JSONValue) -> [String] {
        guard let before = original.objectValue, let after = updated.objectValue else {
            return ["root is not an object"]
        }
        var problems: [String] = []
        for member in before.members where member.key != "hooks" {
            guard let value = after[member.key], value.semanticallyEquals(member.value) else {
                problems.append("setting \"\(member.key)\" would change")
                continue
            }
        }
        for key in after.keys where key != "hooks" && before[key] == nil {
            problems.append("unexpected new setting \"\(key)\"")
        }
        let foreignBefore = foreignHooks(before["hooks"])
        let foreignAfter = foreignHooks(after["hooks"])
        for (event, groups) in foreignBefore {
            let afterGroups = foreignAfter[event] ?? []
            if !JSONValue.array(groups).semanticallyEquals(.array(afterGroups)) {
                problems.append("existing hooks for \(event) would change")
            }
        }
        for (event, groups) in foreignAfter where foreignBefore[event] == nil && !groups.isEmpty {
            problems.append("unexpected hooks added for \(event)")
        }
        return problems
    }

    /// Everything under `hooks` that is not ours, normalized for comparison.
    private static func foreignHooks(_ hooks: JSONValue?) -> [String: [JSONValue]] {
        guard let object = hooks?.objectValue else { return [:] }
        var result: [String: [JSONValue]] = [:]
        for member in object.members {
            guard let groups = member.value.arrayValue else {
                result[member.key] = [member.value]
                continue
            }
            var kept: [JSONValue] = []
            for group in groups {
                guard var groupObject = group.objectValue, let handlers = groupObject["hooks"]?.arrayValue else {
                    kept.append(group)
                    continue
                }
                let foreign = handlers.filter { !isOurs($0) }
                if foreign.isEmpty, !handlers.isEmpty { continue }
                groupObject["hooks"] = .array(foreign)
                kept.append(.object(groupObject))
            }
            if !kept.isEmpty { result[member.key] = kept }
        }
        return result
    }
}

/// Reads, backs up, merges and atomically writes Claude Code's settings file.
public struct ClaudeHookInstaller: Sendable {
    public enum InstallError: Error, CustomStringConvertible, Equatable {
        case unreadable(String)
        case invalidJSON(String)
        case merge(String)
        case backupFailed(String)
        case writeFailed(String)
        case changedDuringInstall
        case helperMissing(String)

        public var description: String {
            switch self {
            case .unreadable(let reason): return "Could not read Claude Code settings: \(reason)"
            case .invalidJSON(let reason): return "Claude Code settings are not valid JSON (\(reason)). Nothing was changed."
            case .merge(let reason): return "Could not merge hooks safely: \(reason). Nothing was changed."
            case .backupFailed(let reason): return "Could not back up settings: \(reason). Nothing was changed."
            case .writeFailed(let reason): return "Could not write settings: \(reason)"
            case .changedDuringInstall: return "settings.json changed while installing. Nothing was changed; please try again."
            case .helperMissing(let path): return "The hook helper is missing at \(path)."
            }
        }
    }

    public enum Status: Equatable, Sendable {
        /// No MacTamagotchi hooks are present.
        case notInstalled
        /// Every requested event has exactly our current command.
        case installed
        /// Some events are missing, duplicated, or point at an old helper path.
        case needsUpdate(missing: [String], outdated: [String])
        case unreadable(String)
    }

    public struct Inspection: Equatable, Sendable {
        public var settingsFile: URL
        public var fileExists: Bool
        public var status: Status
        public var installedEvents: [String]
        /// Number of hook handlers in the file that are not MacTamagotchi's.
        public var otherHookCount: Int
        public var hooksDisabled: Bool
        public var managedHooksOnly: Bool
    }

    public struct Result: Equatable, Sendable {
        public var backup: URL?
        public var changed: Bool
        public var events: [String]
    }

    public var settingsFile: URL
    public var backupDirectory: URL
    public var helperPath: String
    public var environment: [String: String]
    public var managedSettingsFile: URL

    public static var defaultSettingsFile: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".claude/settings.json")
    }

    public init(
        settingsFile: URL = ClaudeHookInstaller.defaultSettingsFile,
        backupDirectory: URL,
        helperPath: String,
        environment: [String: String] = [:],
        managedSettingsFile: URL = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")
    ) {
        self.settingsFile = settingsFile
        self.backupDirectory = backupDirectory
        self.helperPath = helperPath
        self.environment = environment
        self.managedSettingsFile = managedSettingsFile
    }

    public func commands(for events: [ClaudeHookEvent]) -> [ClaudeHookEvent: String] {
        Dictionary(uniqueKeysWithValues: events.map {
            ($0, HookSettingsMerger.command(helperPath: helperPath, event: $0, environment: environment))
        })
    }

    /// Follows a symlinked settings file (dotfile managers) so we edit the target.
    var resolvedSettingsFile: URL { settingsFile.resolvingSymlinksInPath() }

    func readCurrent() throws -> (data: Data?, value: JSONValue) {
        let url = resolvedSettingsFile
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, .object(JSONObject())) }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw InstallError.unreadable(error.localizedDescription)
        }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return (data, .object(JSONObject()))
        }
        do {
            return (data, try OrderedJSON.parse(data))
        } catch {
            throw InstallError.invalidJSON(String(describing: error))
        }
    }

    public func inspect(events: [ClaudeHookEvent]) -> Inspection {
        let exists = FileManager.default.fileExists(atPath: resolvedSettingsFile.path)
        let managedOnly = Self.managedHooksOnly(managedSettingsFile)
        let current: JSONValue
        do {
            current = try readCurrent().value
        } catch {
            return Inspection(settingsFile: settingsFile, fileExists: exists, status: .unreadable(String(describing: error)),
                              installedEvents: [], otherHookCount: 0, hooksDisabled: false, managedHooksOnly: managedOnly)
        }
        let installed = HookSettingsMerger.installedCommands(in: current)
        let expected = commands(for: events)
        var missing: [String] = []
        var outdated: [String] = []
        for event in events {
            let found = installed[event.rawValue] ?? []
            if found.isEmpty {
                missing.append(event.rawValue)
            } else if found != [expected[event]!] {
                outdated.append(event.rawValue)
            }
        }
        for key in installed.keys where !events.contains(where: { $0.rawValue == key }) {
            outdated.append(key)
        }
        let status: Status
        if installed.isEmpty {
            status = .notInstalled
        } else if missing.isEmpty, outdated.isEmpty {
            status = .installed
        } else {
            status = .needsUpdate(missing: missing, outdated: outdated.sorted())
        }
        var otherHooks = 0
        if let hooks = current.objectValue?["hooks"]?.objectValue {
            for member in hooks.members {
                for group in member.value.arrayValue ?? [] {
                    otherHooks += (group.objectValue?["hooks"]?.arrayValue ?? []).filter { !HookSettingsMerger.isOurs($0) }.count
                }
            }
        }
        return Inspection(
            settingsFile: settingsFile,
            fileExists: exists,
            status: status,
            installedEvents: installed.keys.sorted(),
            otherHookCount: otherHooks,
            hooksDisabled: current.objectValue?["disableAllHooks"]?.boolValue == true,
            managedHooksOnly: managedOnly
        )
    }

    /// The exact text that would be written, without writing it.
    public func preview(events: [ClaudeHookEvent]) throws -> String {
        let current = try readCurrent()
        do {
            return OrderedJSON.serialize(try HookSettingsMerger.merge(current.value, commands: commands(for: events)))
        } catch {
            throw InstallError.merge(String(describing: error))
        }
    }

    @discardableResult
    public func install(events: [ClaudeHookEvent], now: Date = Date()) throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else { throw InstallError.helperMissing(helperPath) }
        return try rewrite(now: now, eventNames: events.map(\.rawValue)) { value in
            try HookSettingsMerger.merge(value, commands: commands(for: events))
        }
    }

    @discardableResult
    public func uninstall(now: Date = Date()) throws -> Result {
        try rewrite(now: now, eventNames: []) { value in
            try HookSettingsMerger.removeOurs(value)
        }
    }

    private func rewrite(now: Date, eventNames: [String], transform: (JSONValue) throws -> JSONValue) throws -> Result {
        let target = resolvedSettingsFile
        let current = try readCurrent()
        let updated: JSONValue
        do {
            updated = try transform(current.value)
        } catch {
            throw InstallError.merge(String(describing: error))
        }
        if updated == current.value, current.data != nil {
            return Result(backup: nil, changed: false, events: eventNames)
        }
        if current.data == nil, case .object(let object) = updated, object.members.isEmpty {
            return Result(backup: nil, changed: false, events: eventNames)
        }

        var text = OrderedJSON.serialize(updated)
        // Keep the original file's trailing-newline convention (default: newline).
        if current.data.map({ $0.last == 0x0A }) ?? true { text += "\n" }
        let output = Data(text.utf8)
        // Validate what we are about to write by parsing it back.
        guard let reparsed = try? OrderedJSON.parse(output), reparsed == updated else {
            throw InstallError.merge("generated settings did not round-trip")
        }

        var backupURL: URL?
        if let original = current.data {
            backupURL = try backup(original, now: now)
        }

        // Refuse if someone else changed the file since we read it.
        let latest = FileManager.default.fileExists(atPath: target.path) ? try? Data(contentsOf: target) : nil
        guard latest == current.data else { throw InstallError.changedDuringInstall }

        try atomicWrite(output, to: target)
        return Result(backup: backupURL, changed: true, events: eventNames)
    }

    private func backup(_ data: Data, now: Date) throws -> URL {
        guard BridgePaths.ensurePrivateDirectory(backupDirectory) else {
            throw InstallError.backupFailed("cannot create \(backupDirectory.path)")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: now)
        // Two changes within the same millisecond must not collide; never overwrite a backup.
        var url = backupDirectory.appendingPathComponent("claude-settings-\(stamp).json")
        var attempt = 1
        while FileManager.default.fileExists(atPath: url.path) {
            attempt += 1
            url = backupDirectory.appendingPathComponent("claude-settings-\(stamp)-\(attempt).json")
        }
        do {
            try data.write(to: url, options: [.withoutOverwriting])
            chmod(url.path, 0o600)
        } catch {
            throw InstallError.backupFailed(error.localizedDescription)
        }
        pruneBackups(keep: 20)
        return url
    }

    public func backups() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix("claude-settings-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func pruneBackups(keep: Int) {
        for url in backups().dropFirst(keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func atomicWrite(_ data: Data, to target: URL) throws {
        let directory = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
        var permissions: Int = 0o644
        if let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
           let existing = attributes[.posixPermissions] as? NSNumber {
            permissions = existing.intValue
        }
        let temporary = directory.appendingPathComponent(".settings.json.mactamagotchi-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: permissions]) else {
            throw InstallError.writeFailed("cannot create temporary file in \(directory.path)")
        }
        if rename(temporary.path, target.path) != 0 {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw InstallError.writeFailed(reason)
        }
    }

    static func managedHooksOnly(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let value = try? OrderedJSON.parse(data) else { return false }
        return value.objectValue?["allowManagedHooksOnly"]?.boolValue == true
    }
}
