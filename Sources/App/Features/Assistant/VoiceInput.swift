import AVFoundation
import Foundation
import Speech

/// Hold-to-talk speech recognition with Apple's on-device SpeechAnalyzer (macOS 26 and later).
/// The microphone runs only between `start` and `stop`; audio is never stored or sent anywhere.
@MainActor
final class VoiceInput {
    private var engine: AVAudioEngine?
    private var pipeline: AnyObject?
    private var resultsTask: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""
    private var generation = 0

    var isSupported: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    var microphoneAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var microphoneDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    /// Starts listening; `heard` gets the running transcript, `failed` a sentence to show.
    func start(heard: @escaping @MainActor (String) -> Void, failed: @escaping @MainActor (String) -> Void) {
        cancel()
        generation += 1
        let current = generation
        finalized = ""
        volatile = ""
        guard #available(macOS 26, *) else {
            failed("Talking to me needs macOS 26 or later — you can still type.")
            return
        }
        Task {
            do {
                guard await self.requestMicrophone() else {
                    failed("I can't hear you — allow the microphone in System Settings › Privacy & Security › Microphone.")
                    return
                }
                guard current == self.generation else { return }
                try await self.begin(heard: heard)
            } catch {
                guard current == self.generation else { return }
                self.cancel()
                failed("Listening didn't start (\(error.localizedDescription)).")
            }
        }
    }

    /// Stops the microphone and returns everything heard.
    func stop() async -> String? {
        generation += 1
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if #available(macOS 26, *), let pipeline = pipeline as? Pipeline {
            pipeline.continuation.finish()
            try? await pipeline.analyzer.finalizeAndFinishThroughEndOfInput()
            let results = resultsTask
            let waited = Task { await results?.value }
            let timeout = Task { try? await Task.sleep(for: .seconds(2)) }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await waited.value }
                group.addTask { await timeout.value }
                await group.next()
                group.cancelAll()
            }
        }
        resultsTask?.cancel()
        resultsTask = nil
        pipeline = nil
        let text = (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func cancel() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if #available(macOS 26, *), let pipeline = pipeline as? Pipeline { pipeline.continuation.finish() }
        resultsTask?.cancel()
        resultsTask = nil
        pipeline = nil
    }

    private func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    @available(macOS 26, *)
    private final class Pipeline {
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation

        init(analyzer: SpeechAnalyzer, continuation: AsyncStream<AnalyzerInput>.Continuation) {
            self.analyzer = analyzer
            self.continuation = continuation
        }
    }

    @available(macOS 26, *)
    private func begin(heard: @escaping @MainActor (String) -> Void) async throws {
        var supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if supported == nil { supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        let locale = supported ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            heard("Getting my ears ready…")
            try await installation.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceError.noFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        pipeline = Pipeline(analyzer: analyzer, continuation: continuation)

        resultsTask = Task { [weak self] in
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
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw VoiceError.noMicrophone }
        let converter = TapConverter(from: inputFormat, to: format)
        Self.installTap(on: input, format: inputFormat, converter: converter, continuation: continuation)
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Nonisolated so the tap block is not tied to the main actor (it runs on the audio thread).
    @available(macOS 26, *)
    private nonisolated static func installTap(on node: AVAudioInputNode, format: AVAudioFormat, converter: TapConverter,
                                               continuation: AsyncStream<AnalyzerInput>.Continuation) {
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if let converted = converter.convert(buffer) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }
    }

    enum VoiceError: LocalizedError {
        case noFormat, noMicrophone
        var errorDescription: String? {
            switch self {
            case .noFormat: return "no speech model for this language"
            case .noMicrophone: return "no microphone"
            }
        }
    }
}

/// Converts microphone buffers to the analyzer's format, on the audio thread.
private final class TapConverter: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let format: AVAudioFormat

    init(from input: AVAudioFormat, to output: AVAudioFormat) {
        format = output
        converter = input == output ? nil : AVAudioConverter(from: input, to: output)
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let supplied = Supplied()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied.done {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied.done = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }

    private final class Supplied: @unchecked Sendable {
        var done = false
    }
}
