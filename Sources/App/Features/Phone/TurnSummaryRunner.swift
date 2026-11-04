import Foundation
import TamagotchiCore

/// Runs one short `claude -p` that turns Claude's closing message into a note for the iPhone
/// (`TurnSummarizer`: Haiku, no tools, none of the user's settings, nothing saved). Gives up after
/// `timeout`, so a stuck run never holds a summary back for long.
enum TurnSummaryRunner {
    static func run(prompt: String, executable: String, directory: URL, environment: [String: String],
                    timeout: TimeInterval = 45) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(prompt: prompt, executable: executable, directory: directory,
                                                           environment: environment, timeout: timeout))
            }
        }
    }

    private static func runBlocking(prompt: String, executable: String, directory: URL, environment: [String: String],
                                    timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = TurnSummarizer.arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        try? input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return TurnSummarizer.result(fromOutput: data)
    }
}
