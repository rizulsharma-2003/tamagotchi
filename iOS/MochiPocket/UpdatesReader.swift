import AVFoundation
import NaturalLanguage
import Observation
import TamagotchiCore

/// Reads "Waiting for you" out loud in Mochi's voice (`MochiVoice`), all on this iPhone: Kokoro sentence by sentence
/// (each one plays while the next is made), or an iPhone voice, both through a pitch shifter. A second tap stops it.
/// Siri's "What's waiting" uses it too, so Mochi always sounds the same.
@MainActor
@Observable
final class UpdatesReader {
    static let shared = UpdatesReader()

    private(set) var speaking = false

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let pitch = AVAudioUnitTimePitch()
    /// The audio format the player is wired for (the voice's).
    @ObservationIgnored private var format: AVAudioFormat?
    /// Which reading is current; audio and callbacks from an older one are ignored.
    @ObservationIgnored private var reading = 0
    /// Audio handed to the player but not heard yet.
    @ObservationIgnored private var queued = 0
    /// The voice has handed over the whole reading.
    @ObservationIgnored private var written = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        engine.attach(player)
        engine.attach(pitch)
        let center = NotificationCenter.default
        // After a call, an alarm or Siri talking, or when headphones come and go, pick up where Mochi was.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init) == .ended else { return }
            MainActor.assumeIsolated { self?.carryOn() }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.carryOn() }
        })
    }

    func toggle(_ items: [AgentNote]) {
        if speaking {
            stop()
        } else {
            say(AgentSpeech.script(items: items))
        }
    }

    /// For Siri: starts reading and returns once Mochi can be heard (several seconds at most), so the app is already
    /// playing audio, and stays awake to finish, when Siri hands back. Kokoro gets 5 seconds to load before the
    /// iPhone voice reads instead.
    func speakForSiri(_ items: [AgentNote]) async {
        say(AgentSpeech.script(items: items), patience: 5)
        let deadline = Date().addingTimeInterval(9)
        while speaking, !player.isPlaying, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Says `text` in Mochi's voice: the one set in Settings, or `voice` (a preview). `patience` is how long to
    /// wait for Kokoro to load before the iPhone voice reads instead.
    func say(_ text: String, voice: MochiVoice = .current, patience: TimeInterval = 20) {
        stop()
        let reading = reading
        speaking = true
        Task { await begin(text, voice: voice, patience: patience, reading: reading) }
    }

    func stop() {
        reading += 1
        synthesizer.stopSpeaking(at: .immediate)
        if speaking { finish() }
    }

    private func begin(_ text: String, voice: MochiVoice, patience: TimeInterval, reading: Int) async {
        // Spoken audio plays even with the ring switch on silent, and other sound dips while Mochi talks. Right after
        // Siri the audio can be busy for a moment, so keep trying for a few seconds.
        let session = AVAudioSession.sharedInstance()
        for attempt in 1...12 {
            guard reading == self.reading else { return }
            do {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true)
                break
            } catch {
                if attempt == 12 {
                    finish()
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        guard reading == self.reading else { return }
        written = false
        queued = 0
        if voice.natural, await kokoroReady(within: patience, reading: reading) {
            await speakNaturally(text, voice: voice, reading: reading)
        } else if reading == self.reading {
            speakWithIPhoneVoice(text, voice: voice, reading: reading)
        }
    }

    /// Waits up to `seconds` for Kokoro to load (it keeps loading afterwards, ready for next time).
    private func kokoroReady(within seconds: TimeInterval, reading: Int) async -> Bool {
        let kokoro = KokoroVoice.shared
        if kokoro.loaded { return true }
        Task { await kokoro.prepare() }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, reading == self.reading {
            if kokoro.loaded { return true }
            if case .failed = kokoro.phase { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return kokoro.loaded
    }

    /// Kokoro, a sentence at a time: each plays while the next is made. If it fails before a word, the iPhone voice
    /// reads it all instead.
    private func speakNaturally(_ text: String, voice: MochiVoice, reading: Int) async {
        pitch.pitch = voice.style.cents
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)
        var spoken = false
        for sentence in Self.sentences(text) {
            guard reading == self.reading else { return }
            do {
                let samples = try await KokoroVoice.shared.speech(sentence, style: voice.style)
                guard reading == self.reading else { return }
                // A short breath between sentences, as Kokoro makes each one on its own.
                if let format, let buffer = Self.buffer(samples, pause: 0.12, format: format) {
                    receive(buffer, reading: reading)
                    spoken = true
                }
            } catch {
                MacLink.shared.log("kokoro: reading failed \(error)")
                if !spoken {
                    speakWithIPhoneVoice(text, voice: voice, reading: reading)
                    return
                }
                break
            }
        }
        KokoroVoice.shared.idle()
        allWritten(reading: reading)
    }

    private func speakWithIPhoneVoice(_ text: String, voice: MochiVoice, reading: Int) {
        pitch.pitch = voice.character.cents
        synthesizer.write(voice.utterance(text)) { [weak self] buffer in
            guard let buffer = buffer as? AVAudioPCMBuffer else { return }
            let audio = Audio(buffer: buffer)
            // The main queue keeps the pieces in order.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(audio.buffer, reading: reading) }
            }
        }
    }

    /// One piece of the reading from the voice; an empty one means it's all there.
    private func receive(_ buffer: AVAudioPCMBuffer, reading: Int) {
        guard reading == self.reading, speaking else { return }
        guard buffer.frameLength > 0 else {
            allWritten(reading: reading)
            return
        }
        if format != buffer.format {
            engine.stop()
            engine.connect(player, to: pitch, format: buffer.format)
            engine.connect(pitch, to: engine.mainMixerNode, format: buffer.format)
            format = buffer.format
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                finish()
                return
            }
        }
        queued += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.heard(reading: reading) }
            }
        }
        if !player.isPlaying { player.play() }
    }

    /// The whole reading has been handed to the player; finish once it's been heard.
    private func allWritten(reading: Int) {
        guard reading == self.reading else { return }
        written = true
        if queued <= 0 { finish() }
    }

    /// Sentences, so Kokoro can start talking after the first one.
    private static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var list: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { list.append(sentence) }
            return true
        }
        return list.isEmpty ? [text] : list
    }

    /// Kokoro's samples as audio the player takes, with `pause` seconds of quiet after them.
    private static func buffer(_ samples: [Float], pause: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }
        let quiet = Int(pause * format.sampleRate)
        let frames = AVAudioFrameCount(samples.count + quiet)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        (channel + samples.count).update(repeating: 0, count: quiet)
        return buffer
    }

    private func heard(reading: Int) {
        guard reading == self.reading else { return }
        queued -= 1
        if written, queued <= 0 { finish() }
    }

    private func carryOn() {
        guard speaking, format != nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try? engine.start() }
        if engine.isRunning, !player.isPlaying { player.play() }
    }

    private func finish() {
        reading += 1
        speaking = false
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Audio handed from the voice's thread to the main one.
private struct Audio: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
