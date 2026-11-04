import CryptoKit
import Foundation

/// File-system locations shared by the app and the hook helper.
///
/// Everything lives under one private directory (mode 0700). Setting
/// `MACTAMAGOTCHI_HOME` points both processes at a different directory, which the
/// test suite and isolated development runs use so they never touch real data.
public struct BridgePaths: Sendable, Equatable {
    public static let homeEnvironmentKey = "MACTAMAGOTCHI_HOME"

    public let home: URL

    public init(home: URL) {
        self.home = home.standardizedFileURL
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> BridgePaths {
        if let override = environment[homeEnvironmentKey], !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return BridgePaths(home: URL(fileURLWithPath: expanded, isDirectory: true))
        }
        let appSupport = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/MacTamagotchi", isDirectory: true)
        return BridgePaths(home: appSupport)
    }

    public var runDirectory: URL { home.appendingPathComponent("run", isDirectory: true) }
    public var spoolDirectory: URL { home.appendingPathComponent("spool", isDirectory: true) }
    public var spoolFile: URL { spoolDirectory.appendingPathComponent("pending.jsonl") }
    public var binDirectory: URL { home.appendingPathComponent("bin", isDirectory: true) }
    public var installedHelper: URL { binDirectory.appendingPathComponent(HelperInfo.executableName) }
    public var backupsDirectory: URL { home.appendingPathComponent("Backups", isDirectory: true) }
    public var journalFile: URL { home.appendingPathComponent("history.jsonl") }
    public var settingsFile: URL { home.appendingPathComponent("settings.json") }
    public var progressFile: URL { home.appendingPathComponent("progress.json") }
    /// Present while the user shares Claude's summaries with their iPhone; only then does the hook
    /// helper include Claude's closing message and the names of changed files.
    public var summariesFlagFile: URL { home.appendingPathComponent("share-summaries") }

    /// `sockaddr_un.sun_path` holds 104 bytes on macOS, including the terminator.
    public static let maxSocketPathBytes = 103

    /// The socket normally lives in `run/`. If that path is too long for
    /// `sockaddr_un`, fall back to a per-user directory under /tmp.
    public var socketFile: URL { socket(named: "bridge") }

    /// Where Mochi's helper Claude session reaches the assistant's tools ("paws").
    public var pawsSocketFile: URL { socket(named: "paws") }

    /// Working directory and configuration of Mochi's helper Claude session.
    public var assistantDirectory: URL { home.appendingPathComponent("Assistant", isDirectory: true) }

    /// What Mochi's agent has already told you, and when it last looked.
    public var agentFile: URL { home.appendingPathComponent("agent.json") }

    private func socket(named name: String) -> URL {
        let preferred = runDirectory.appendingPathComponent("\(name).sock")
        if preferred.path.utf8.count <= BridgePaths.maxSocketPathBytes {
            return preferred
        }
        let digest = SHA256.hash(data: Data(home.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: "/tmp/mactamagotchi-\(getuid())", isDirectory: true)
            .appendingPathComponent(name == "bridge" ? "\(digest).sock" : "\(digest)-\(name).sock")
    }

    /// Creates a directory readable only by the current user.
    @discardableResult
    public static func ensurePrivateDirectory(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                chmod(url.path, 0o700)
                return true
            }
            return false
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            return false
        }
    }
}

public enum ProjectIdentity {
    /// A short, stable, one-way identifier for a project path.
    public static func key(forPath path: String) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return SHA256.hash(data: Data(normalized.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public static func displayName(forPath path: String) -> String {
        let name = URL(fileURLWithPath: path).standardizedFileURL.lastPathComponent
        return WireText.clean(name.isEmpty ? "/" : name, maxLength: 48) ?? "Project"
    }
}

/// Text hygiene for every string that crosses the wire.
public enum WireText {
    /// Collapses whitespace, removes control characters and truncates.
    public static func clean(_ value: String?, maxLength: Int) -> String? {
        guard let value else { return nil }
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace, !scalars.isEmpty { scalars.append(" ") }
                lastWasSpace = true
                continue
            }
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.illegalCharacters.contains(scalar) {
                continue
            }
            scalars.append(scalar)
            lastWasSpace = false
        }
        var text = String(scalars).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.count > maxLength {
            text = String(text.prefix(max(0, maxLength - 1))) + "…"
        }
        return text
    }

    /// Free text whose line breaks matter (Claude's closing message): each line is cleaned, at most
    /// one blank line in a row is kept, and the end is truncated.
    public static func paragraphs(_ value: String?, maxLength: Int) -> String? {
        guard let value else { return nil }
        var lines: [String] = []
        for raw in value.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let line = clean(String(raw), maxLength: Int.max) {
                lines.append(line)
            } else if lines.last.map({ !$0.isEmpty }) == true {
                lines.append("")
            }
        }
        while lines.last == "" { lines.removeLast() }
        var text = lines.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        if text.count > maxLength {
            text = String(text.prefix(max(0, maxLength - 1))) + "…"
        }
        return text
    }

    /// Identifier-like strings (session ids, tool names, event names).
    public static func identifier(_ value: String?, maxLength: Int) -> String? {
        guard let value, !value.isEmpty, value.count <= maxLength else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }
}
