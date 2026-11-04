import Foundation
import TamagotchiCore

/// Runs the agent's short `claude -p` processes off the main thread, giving up after a timeout so a
/// stuck run never holds anything back.
enum AgentRunner {
    /// Everything the run printed (Claude Code prints its JSON even when the run failed), or nil.
    static func run(arguments: [String], input: String, executable: String, directory: URL, environment: [String: String],
                    timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(arguments, input, executable, directory, environment, timeout))
            }
        }
    }

    private static func runBlocking(_ arguments: [String], _ input: String, _ executable: String, _ directory: URL,
                                    _ environment: [String: String], _ timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let stdin = Pipe()
        let output = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop.cancel()
        return data.isEmpty ? nil : data
    }
}
