import AVFoundation
import Foundation
import Speech

/// Hold-to-talk speech recognition on the iPhone (Apple's on-device SpeechAnalyzer). The
/// microphone runs only while you hold Mochi; audio never leaves the phone.
@MainActor
final class PhoneListener {
    private var engine: AVAudioEngine?
    private var continuation: AnyObject?
    private var analyzer: AnyObject?
    private var results: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""

    enum Problem: LocalizedError {
        case microphone, unsupported, noFormat
        var errorDescription: String? {
            switch self {
            case .microphone: return "Mochi can't hear you — allow the microphone in Settings › Mochi."
            case .unsupported: return "Talking to Mochi needs iOS 26 or later."
            case .noFormat: return "Speech isn't available in this language yet."
            }
        }
    }

    func start(heard: @escaping @MainActor (String) -> Void) async throws {
        cancel()
        finalized = ""
        volatile = ""
        guard #available(iOS 26, *) else { throw Problem.unsupported }
        guard await AVAudioApplication.requestRecordPermission() else { throw Problem.microphone }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        try await begin(heard: heard)
    }

    func stop() async -> String? {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if #available(iOS 26, *) {
            (continuation as? AsyncStream<AnalyzerInput>.Continuation)?.finish()
            let analyzer = analyzer as? SpeechAnalyzer
            let pending = results
            // The last words, but never more than two seconds' wait, so Mochi can't get stuck listening.
            await Self.wait(atMost: 2) {
                try? await analyzer?.finalizeAndFinishThroughEndOfInput()
                await pending?.value
            }
        }
        results?.cancel()
        results = nil
        analyzer = nil
        continuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let text = (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Returns when `work` finishes or after `seconds`, whichever is first; a task group would wait for both.
    private nonisolated static func wait(atMost seconds: Double, for work: @escaping @Sendable () async -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task { await work(); once.resume() }
            Task { try? await Task.sleep(for: .seconds(seconds)); once.resume() }
        }
    }

    func cancel() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if #available(iOS 26, *) { (continuation as? AsyncStream<AnalyzerInput>.Continuation)?.finish() }
        results?.cancel()
        results = nil
        analyzer = nil
        continuation = nil
    }

    @available(iOS 26, *)
    private func begin(heard: @escaping @MainActor (String) -> Void) async throws {
        var supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if supported == nil { supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        let transcriber = SpeechTranscriber(locale: supported ?? Locale(identifier: "en-US"), preset: .progressiveTranscription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            heard("Getting my ears ready…")
            try await installation.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw Problem.noFormat }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.analyzer = analyzer
        self.continuation = continuation as AnyObject
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalized += text
                        self.volatile = ""
                    } else {
                        self.volatile = text
                    }
                    heard((self.finalized + self.volatile).trimmingCharacters(in: .whitespaces))
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let converter = MicConverter(from: inputFormat, to: format)
        Self.installTap(on: input, format: inputFormat, converter: converter, continuation: continuation)
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    @available(iOS 26, *)
    private nonisolated static func installTap(on node: AVAudioInputNode, format: AVAudioFormat, converter: MicConverter,
                                               continuation: AsyncStream<AnalyzerInput>.Continuation) {
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if let converted = converter.convert(buffer) { continuation.yield(AnalyzerInput(buffer: converted)) }
        }
    }
}

/// Converts microphone buffers to the analyzer's format, on the audio thread.
private final class MicConverter: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let format: AVAudioFormat

    init(from input: AVAudioFormat, to output: AVAudioFormat) {
        format = output
        converter = input == output ? nil : AVAudioConverter(from: input, to: output)
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if once.done {
                inputStatus.pointee = .noDataNow
                return nil
            }
            once.done = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
