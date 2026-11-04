import Darwin
import Foundation
import TamagotchiWire

// mactamagotchi-hook
//
//   claude-hook [EventName]   Invoked by Claude Code hooks. Reads the hook payload
//                             from stdin, forwards a sanitized summary to the app.
//                             Never prints to stdout and always exits 0, so it can
//                             neither block Claude nor inject anything into context.
//   report <kind> <status> [--label TEXT]
//                             Report an explicit result from your own scripts, e.g.
//                             `swift test && mactamagotchi-hook report test passed`.
//                             kind: build | test | milestone | commit
//                             status: passed | failed | reached
//   ping                      Check whether the app is listening.
//   paws                      Started by MacTamagotchi for Mochi's helper Claude session: relays
//                             the assistant's tool calls (MCP over stdio) to the app's private
//                             socket. Refuses to run without the token the app hands it.
//   --version

// A hook must never hang Claude Code: hard deadline, then exit quietly.
signal(SIGALRM) { _ in _exit(0) }
signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment
let paths = BridgePaths.resolve(environment: environment)

func readStdin(limit: Int) -> Data {
    if isatty(STDIN_FILENO) != 0 { return Data() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count <= 0 { break }
        // Keep reading past the limit so the writer is never left blocked, but
        // stop keeping bytes; the sanitizer then falls back to a bounded head scan.
        if data.count < limit { data.append(contentsOf: buffer.prefix(count)) }
    }
    return data
}

func deliver(_ event: WireEvent) -> BridgeClient.Outcome {
    guard let line = try? event.encodedLine() else { return .rejected("encoding failed") }
    let outcome = BridgeClient.send(line, to: paths.socketFile)
    if case .unavailable = outcome, event.origin != .ping, let kept = try? event.withoutSummary.encodedLine() {
        // The app is not running: keep a bounded record so it can show what was missed
        // (never Claude's words: summaries are only held in memory).
        EventSpool.append(kept, to: paths.spoolFile)
    }
    return outcome
}

func runClaudeHook() -> Never {
    alarm(3)
    let raw = readStdin(limit: HookPayloadSanitizer.maxParsedBytes + 1)
    let event = HookPayloadSanitizer.sanitize(
        raw: raw,
        argumentEvent: arguments.dropFirst().first,
        environment: environment,
        includeSummary: FileManager.default.fileExists(atPath: paths.summariesFlagFile.path)
    )
    _ = deliver(event)
    exit(0)
}

func value(after flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func runReport(_ args: [String]) -> Never {
    alarm(3)
    let kinds = ["build", "test", "milestone", "commit"]
    let statuses = ["passed", "failed", "reached"]
    guard args.count >= 2, kinds.contains(args[0]), statuses.contains(args[1]) else {
        FileHandle.standardError.write(Data("usage: mactamagotchi-hook report <build|test|milestone|commit> <passed|failed|reached> [--label TEXT]\n".utf8))
        exit(64)
    }
    let label = WireText.clean(value(after: "--label", in: args), maxLength: 60)
    let now = Date()
    let id = "report-\(UUID().uuidString.lowercased())"
    var event = WireEvent(id: id, ts: now.timeIntervalSince1970, origin: .report, event: "Report")
    event.report = WireReport(kind: args[0], status: args[1], label: label)
    event.helperVersion = HelperInfo.version
    // Commands run by Claude Code inherit its session id, so their reports attach to that session.
    let sessionID = value(after: "--session", in: args) ?? environment["CLAUDE_CODE_SESSION_ID"] ?? environment["CLAUDE_SESSION_ID"]
    event.session = WireText.identifier(sessionID, maxLength: 128)
    let projectPath = environment["CLAUDE_PROJECT_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? FileManager.default.currentDirectoryPath
    event.project = WireText.clean(value(after: "--project", in: args), maxLength: 48) ?? ProjectIdentity.displayName(forPath: projectPath)
    event.projectKey = ProjectIdentity.key(forPath: projectPath)
    event.projectPath = projectPath

    switch deliver(event) {
    case .accepted:
        break
    case .rejected(let reason):
        FileHandle.standardError.write(Data("mactamagotchi: report not accepted (\(reason))\n".utf8))
    case .unavailable:
        FileHandle.standardError.write(Data("mactamagotchi: app not running; report saved and will be shown as late\n".utf8))
    }
    // Never change the exit status of the user's script.
    exit(0)
}

func runPing() -> Never {
    alarm(3)
    var event = WireEvent(id: "ping-\(UUID().uuidString.lowercased())", ts: Date().timeIntervalSince1970, origin: .ping, event: "Ping")
    event.helperVersion = HelperInfo.version
    switch deliver(event) {
    case .accepted:
        print("MacTamagotchi is listening at \(paths.socketFile.path)")
        exit(0)
    case .rejected(let reason):
        print("MacTamagotchi answered but rejected the ping: \(reason)")
        exit(1)
    case .unavailable(let reason):
        print("MacTamagotchi is not reachable: \(reason)")
        exit(1)
    }
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var offset = 0
    while offset < data.count {
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
        if written < 0, errno == EINTR { continue }
        if written <= 0 { return false }
        offset += written
    }
    return true
}

func pump(from source: Int32, to destination: Int32) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = read(source, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        if count <= 0 { return }
        if !writeAll(destination, Data(buffer.prefix(count))) { return }
    }
}

func runPaws() -> Never {
    guard let token = environment["MACTAMAGOTCHI_PAWS_TOKEN"], (16...128).contains(token.count), token.allSatisfy(\.isHexDigit),
          let socketPath = environment["MACTAMAGOTCHI_PAWS_SOCKET"], !socketPath.isEmpty else {
        FileHandle.standardError.write(Data("mactamagotchi: paws is started by MacTamagotchi itself\n".utf8))
        exit(64)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0, var address = BridgeClient.makeAddress(socketPath) else { exit(69) }
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0, writeAll(fd, Data("{\"auth\":\"\(token)\"}\n".utf8)) else {
        FileHandle.standardError.write(Data("mactamagotchi: the app is not listening\n".utf8))
        exit(69)
    }
    // stdin → app on a second thread, app → stdout here; either side closing ends the relay.
    DispatchQueue.global().async {
        pump(from: STDIN_FILENO, to: fd)
        shutdown(fd, SHUT_WR)
    }
    pump(from: fd, to: STDOUT_FILENO)
    exit(0)
}

switch arguments.first {
case HelperInfo.hookSubcommand:
    runClaudeHook()
case "report":
    runReport(Array(arguments.dropFirst()))
case "ping":
    runPing()
case "paws":
    runPaws()
case "--version", "version":
    print("mactamagotchi-hook \(HelperInfo.version)")
default:
    print("""
    mactamagotchi-hook \(HelperInfo.version)

    usage:
      mactamagotchi-hook claude-hook [EventName]     (used by Claude Code hooks; reads stdin)
      mactamagotchi-hook report <build|test|milestone|commit> <passed|failed|reached> [--label TEXT]
      mactamagotchi-hook ping
    """)
}
