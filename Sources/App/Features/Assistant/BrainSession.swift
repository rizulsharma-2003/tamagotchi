import Foundation
import TamagotchiCore

/// Mochi's helper Claude session: one long-lived `claude -p` process with streaming input and
/// output. Requests go in as user messages; events come back on the main actor, in order.
@MainActor
final class BrainSession {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lines = LineBuffer()
    private let errorTail = LineBuffer()

    var onEvent: ((BrainEvent) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    private(set) var isRunning = false

    init(launch: BrainLaunch) {
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: launch.workingDirectory, isDirectory: true)
        process.environment = Self.environment()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    /// The app's environment minus anything that would tie the helper to another Claude session
    /// (when the app itself was started from one) and with a PATH that finds the usual tools.
    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("CLAUDE") || key.hasPrefix("MACTAMAGOTCHI_") || key.hasPrefix("VSCODE_")
            || key == "__CFBundleIdentifier" || key == "TERM_PROGRAM" {
            environment[key] = nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .joined(separator: ":")
        environment["NO_COLOR"] = "1"
        return environment
    }

    func start() throws {
        let lines = lines
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let events = lines.append(data).flatMap(BrainEvent.parse)
            guard !events.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for event in events { self?.onEvent?(event) }
                }
            }
        }
        let errorTail = errorTail
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { errorTail.keepTail(data) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            let tail = errorTail.text
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isRunning = false
                    self.onExit?(status, tail)
                }
            }
        }
        try process.run()
        isRunning = true
    }

    func send(_ text: String) {
        guard isRunning else { return }
        try? input.fileHandleForWriting.write(contentsOf: BrainLaunch.inputLine(text))
    }

    func terminate() {
        guard isRunning else { return }
        isRunning = false
        try? input.fileHandleForWriting.close()
        process.interrupt()
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Splits a byte stream into complete lines; also keeps a short tail for error reports.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var tail = Data()

    /// Appends bytes and returns the complete lines now available.
    func append(_ data: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if buffer.count > 4 * 1024 * 1024 { buffer.removeAll() }
        return lines
    }

    func keepTail(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        tail.append(data)
        if tail.count > 2048 { tail = tail.suffix(2048) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: tail, as: UTF8.self)
    }
}
