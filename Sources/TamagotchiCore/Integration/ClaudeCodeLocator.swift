import Foundation

public struct ClaudeInstallation: Sendable, Equatable {
    public var executable: URL
    /// The file the executable resolves to (native binary or `cli.js`).
    public var resolved: URL
    public var version: String?

    public var versionComponents: [Int] {
        guard let version else { return [] }
        let numeric = version.split(separator: " ").first ?? ""
        return numeric.split(separator: ".").compactMap { Int($0) }
    }
}

/// Finds the installed Claude Code CLI. GUI apps do not inherit the shell's PATH,
/// so well-known install locations are checked as well as PATH.
public enum ClaudeCodeLocator {
    public static func candidatePaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let home = NSHomeDirectory()
        var paths = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
            "\(home)/Library/pnpm/claude",
        ]
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":") where !directory.isEmpty {
                paths.append("\(directory)/claude")
            }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeInstallation? {
        let fm = FileManager.default
        // MACTAMAGOTCHI_CLAUDE_BIN pins the CLI (or, pointing at nothing, simulates "not installed").
        if let pinned = environment["MACTAMAGOTCHI_CLAUDE_BIN"], !pinned.isEmpty {
            guard fm.isExecutableFile(atPath: pinned) else { return nil }
            let url = URL(fileURLWithPath: pinned)
            return ClaudeInstallation(executable: url, resolved: url.resolvingSymlinksInPath(), version: readVersion(url))
        }
        for path in candidatePaths(environment: environment) where fm.isExecutableFile(atPath: path) {
            let url = URL(fileURLWithPath: path)
            let resolved = url.resolvingSymlinksInPath()
            return ClaudeInstallation(executable: url, resolved: resolved, version: readVersion(url))
        }
        return nil
    }

    /// Runs `claude --version` (a documented flag) with a short timeout.
    public static func readVersion(_ executable: URL, timeout: TimeInterval = 6) -> String? {
        #if !os(macOS)
        return nil
        #else
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDECODE"] = nil
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.split(separator: "\n").first else { return nil }
        let version = first.split(separator: " ").first.map(String.init)
        guard let version, version.first?.isNumber == true else { return nil }
        return version
        #endif
    }
}

/// Determines which hook events the installed Claude Code supports.
///
/// The installed CLI is inspected for each event's name as a string literal. If
/// that is not possible (unknown packaging, unreadable file), only the
/// long-established core events are used, so an unknown event name is never
/// written into the user's settings.
public enum HookCompatibility {
    public struct Report: Sendable, Equatable, Codable {
        public var claudeVersion: String?
        public var supported: [ClaudeHookEvent]
        public var unsupported: [ClaudeHookEvent]
        /// "inspected" when the installed CLI was examined, "assumed" for the core fallback.
        public var method: String
    }

    public static func detect(installation: ClaudeInstallation?) -> Report {
        guard let installation, let found = scan(installation.resolved) else {
            let core = ClaudeHookEvent.allCases.filter(\.isCore)
            return Report(
                claudeVersion: installation?.version,
                supported: core,
                unsupported: ClaudeHookEvent.allCases.filter { !$0.isCore },
                method: "assumed"
            )
        }
        return Report(
            claudeVersion: installation.version,
            supported: ClaudeHookEvent.allCases.filter { found.contains($0) },
            unsupported: ClaudeHookEvent.allCases.filter { !found.contains($0) },
            method: "inspected"
        )
    }

    /// Searches the file for `"EventName"` byte patterns. Returns nil if the file
    /// cannot be read or does not look like Claude Code at all.
    static func scan(_ file: URL) -> Set<ClaudeHookEvent>? {
        guard let data = try? Data(contentsOf: file, options: [.alwaysMapped]), data.count > 1024 else { return nil }
        var found = Set<ClaudeHookEvent>()
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            for event in ClaudeHookEvent.allCases {
                let needle = Array("\"\(event.rawValue)\"".utf8)
                let hit = needle.withUnsafeBytes { needleBuffer in
                    memmem(base, buffer.count, needleBuffer.baseAddress, needle.count)
                }
                if hit != nil { found.insert(event) }
            }
        }
        // Sanity check: a real Claude Code build mentions all core events.
        let core = Set(ClaudeHookEvent.allCases.filter(\.isCore))
        guard core.isSubset(of: found) else { return nil }
        return found
    }
}
