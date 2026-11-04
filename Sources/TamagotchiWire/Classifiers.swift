import Foundation

/// Coarse buckets for tool names. Only the tool *name* (which Claude Code reports
/// in every tool hook) is used; tool inputs are never inspected for this.
public enum ToolCategoryClassifier {
    public static func category(forTool tool: String) -> String {
        switch tool {
        case "Read", "NotebookRead", "LS":
            return "read"
        case "Grep", "Glob", "ToolSearch", "LSP":
            return "search"
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return "edit"
        case "Bash", "BashOutput", "KillShell", "KillBash", "PowerShell", "Monitor":
            return "shell"
        case "WebFetch", "WebSearch":
            return "web"
        case "Task", "Agent", "SendMessage", "TaskStop", "Workflow":
            return "agent"
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "EnterPlanMode", "ExitPlanMode":
            return "plan"
        case "AskUserQuestion":
            return "ask"
        case "Skill", "SlashCommand":
            return "skill"
        default:
            if tool.hasPrefix("mcp__") { return "mcp" }
            return "other"
        }
    }
}

/// Recognizes build and test commands in a Bash tool call without ever keeping
/// the command text. The result is only a kind ("test"/"build") plus whether the
/// command's exit status can honestly be read as the result of that build/test.
public enum CommandClassifier {
    public struct Result: Equatable, Sendable {
        public var kind: String?
        public var reliable: Bool
    }

    private enum Separator { case start, and, or, semicolon, pipe, background }

    public static func classify(_ command: String) -> Result {
        let segments = split(command)
        var matchIndex: Int?
        var matchKind: String?
        for (index, segment) in segments.enumerated() {
            guard let kind = kind(of: segment.text) else { continue }
            // A test anywhere in the command wins over a build.
            if matchKind == nil || (kind == "test" && matchKind == "build") {
                matchKind = kind
                matchIndex = index
            }
        }
        guard let kind = matchKind, let index = matchIndex else {
            return Result(kind: nil, reliable: false)
        }
        // The overall exit status reflects the matched command only when it is
        // not piped or backgrounded and everything after it is chained with `&&`.
        var reliable = true
        for later in segments.dropFirst(index + 1) where later.separator != .and {
            reliable = false
        }
        if segments[index].separator == .pipe || segments[index].separator == .background { reliable = false }
        if command.contains("pipefail") { reliable = false }
        return Result(kind: kind, reliable: reliable)
    }

    private struct Segment {
        var separator: Separator
        var text: String
    }

    /// Splits on top-level `&&`, `||`, `;`, `|`, `&` and newlines, ignoring quoted text.
    private static func split(_ command: String) -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        var separator = Separator.start
        var quote: Character?
        var chars = Array(command)
        if chars.count > 4096 { chars = Array(chars.prefix(4096)) }
        var i = 0
        func flush(next: Separator) {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { segments.append(Segment(separator: separator, text: trimmed)) }
            current = ""
            separator = next
        }
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil }
                current.append(c)
                i += 1
                continue
            }
            switch c {
            case "'", "\"":
                quote = c
                current.append(c)
            case "&" where i + 1 < chars.count && chars[i + 1] == "&":
                flush(next: .and); i += 1
            case "|" where i + 1 < chars.count && chars[i + 1] == "|":
                flush(next: .or); i += 1
            case "|":
                flush(next: .pipe)
            case "&":
                // `2>&1` and `&>` are redirections, not backgrounding.
                if i > 0, chars[i - 1] == ">" || (i + 1 < chars.count && chars[i + 1] == ">") {
                    current.append(c)
                } else {
                    // The segment before a lone `&` runs in the background.
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { segments.append(Segment(separator: .background, text: trimmed)) }
                    current = ""
                    separator = .semicolon
                }
            case ";", "\n":
                flush(next: .semicolon)
            default:
                current.append(c)
            }
            i += 1
        }
        flush(next: .semicolon)
        return segments
    }

    private static let wrappers: Set<String> = ["env", "time", "command", "nice", "npx", "bunx", "xcrun", "exec", "caffeinate", "nohup"]

    private static func kind(of segment: String) -> String? {
        var words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // Drop leading environment assignments and wrapper commands.
        while let first = words.first {
            if first.contains("="), !first.hasPrefix("-"), first.first?.isLetter == true {
                words.removeFirst()
            } else if wrappers.contains(first) || first == "sudo" {
                words.removeFirst()
                while let flag = words.first, flag.hasPrefix("-") { words.removeFirst() }
            } else {
                break
            }
        }
        guard let rawTool = words.first else { return nil }
        let tool = (rawTool as NSString).lastPathComponent
        let args = Array(words.dropFirst()).filter { !$0.hasPrefix("-") }
        let firstArg = args.first ?? ""

        switch tool {
        case "swift":
            if firstArg == "test" { return "test" }
            if firstArg == "build" { return "build" }
        case "xcodebuild":
            if args.contains("test") || args.contains("test-without-building") { return "test" }
            if args.isEmpty || args.contains("build") || args.contains("archive") || args.contains("build-for-testing") { return "build" }
        case "npm", "yarn", "pnpm", "bun":
            if firstArg == "test" || firstArg == "t" { return "test" }
            if firstArg == "build" { return "build" }
            if firstArg == "run" || firstArg == "exec", let script = args.dropFirst().first {
                if script.hasPrefix("test") { return "test" }
                if script.hasPrefix("build") { return "build" }
            }
        case "pytest", "jest", "vitest", "mocha", "rspec", "phpunit", "ctest", "tox", "nox":
            return "test"
        case "python", "python3":
            if words.contains("pytest") || words.contains("unittest") { return "test" }
        case "go", "cargo", "dotnet", "bazel", "deno", "dart", "flutter", "mix", "tuist":
            if firstArg == "test" || firstArg == "nextest" { return "test" }
            if firstArg == "build" { return "build" }
        case "mvn", "mvnw":
            if args.contains("test") || args.contains("verify") { return "test" }
            if args.contains("package") || args.contains("install") || args.contains("compile") { return "build" }
        case "gradle", "gradlew":
            if args.contains(where: { $0 == "test" || $0 == "check" || $0.hasSuffix(":test") }) { return "test" }
            if args.contains(where: { $0 == "build" || $0 == "assemble" || $0.hasPrefix("assemble") }) { return "build" }
        case "make", "gmake":
            if firstArg == "test" || firstArg == "check" { return "test" }
            if args.isEmpty || firstArg == "build" || firstArg == "all" { return "build" }
        case "cmake":
            if words.contains("--build") { return "build" }
        case "tsc", "webpack":
            return "build"
        case "vite", "next", "nuxt", "astro":
            if firstArg == "build" { return "build" }
        case "bundle":
            if args.first == "exec", args.dropFirst().first == "rspec" { return "test" }
        case "rake":
            if firstArg == "test" || firstArg == "spec" { return "test" }
        default:
            break
        }
        return nil
    }
}
