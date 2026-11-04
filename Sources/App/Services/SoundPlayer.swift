import AVFoundation
import TamagotchiCore

/// A tiny original sound palette, synthesized at runtime (no audio files).
/// Soft bell-like tones with gentle envelopes; everything is quiet by design.
@MainActor
final class SoundPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [SoundCue: AVAudioPCMBuffer] = [:]
    private var configured = false
    private var stopTask: Task<Void, Never>?
    var volume: Float = 0.45

    /// macOS "Play user interface sound effects" (Sound settings). When it is off we stay silent too.
    static var systemUISoundsEnabled: Bool {
        let defaults = UserDefaults(suiteName: "com.apple.systemsound")
        guard let value = defaults?.object(forKey: "com.apple.sound.uiaudio.enabled") as? NSNumber else { return true }
        return value.boolValue
    }

    func play(_ cue: SoundCue) {
        guard volume > 0.01, Self.systemUISoundsEnabled, ensureEngine() else { return }
        stopTask?.cancel()
        let buffer = buffers[cue] ?? synthesize(cue)
        buffers[cue] = buffer
        player.volume = max(0, min(1, volume)) * 0.6
        player.scheduleBuffer(buffer, at: nil, options: [.interruptsAtLoop], completionHandler: nil)
        if !player.isPlaying { player.play() }
        // Shut the engine down shortly after the sound, so the audio device can
        // sleep and no IO thread keeps running between sounds.
        let length = Double(buffer.frameLength) / format.sampleRate
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(length + 1.5))
            guard !Task.isCancelled, let self else { return }
            self.player.stop()
            self.engine.stop()
        }
    }

    private func ensureEngine() -> Bool {
        if !configured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            configured = true
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        return true
    }

    private struct Note {
        var frequency: Double
        var start: Double
        var duration: Double
        var amplitude: Double = 0.22
    }

    private func notes(for cue: SoundCue) -> [Note] {
        switch cue {
        case .greeting: return [Note(frequency: 784, start: 0, duration: 0.18), Note(frequency: 1046.5, start: 0.11, duration: 0.32)]
        case .success:
            return [Note(frequency: 1046.5, start: 0, duration: 0.24), Note(frequency: 1318.5, start: 0.09, duration: 0.24),
                    Note(frequency: 1568, start: 0.18, duration: 0.45)]
        case .celebration:
            return [Note(frequency: 1046.5, start: 0, duration: 0.2), Note(frequency: 1318.5, start: 0.08, duration: 0.2),
                    Note(frequency: 1568, start: 0.16, duration: 0.2), Note(frequency: 2093, start: 0.26, duration: 0.55),
                    Note(frequency: 2637, start: 0.36, duration: 0.12, amplitude: 0.1)]
        case .sleep: return [Note(frequency: 880, start: 0, duration: 0.32, amplitude: 0.14), Note(frequency: 659.3, start: 0.2, duration: 0.5, amplitude: 0.12)]
        case .attention: return [Note(frequency: 880, start: 0, duration: 0.18, amplitude: 0.18), Note(frequency: 1174.7, start: 0.15, duration: 0.32, amplitude: 0.18)]
        case .investigate: return [Note(frequency: 587.3, start: 0, duration: 0.22, amplitude: 0.16), Note(frequency: 493.9, start: 0.15, duration: 0.34, amplitude: 0.14)]
        case .pop: return [Note(frequency: 1760, start: 0, duration: 0.09, amplitude: 0.14)]
        case .achievement:
            return [Note(frequency: 784, start: 0, duration: 0.16), Note(frequency: 1046.5, start: 0.1, duration: 0.16),
                    Note(frequency: 1318.5, start: 0.2, duration: 0.16), Note(frequency: 1568, start: 0.3, duration: 0.6)]
        case .keyboard: return []
        }
    }

    private func synthesize(_ cue: SoundCue) -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        if cue == .keyboard {
            return render(length: 0.22, sampleRate: sampleRate) { t in
                var value = 0.0
                for (index, start) in [0.0, 0.07, 0.135].enumerated() {
                    let local = t - start
                    guard local >= 0, local < 0.018 else { continue }
                    let noise = Ease.hash(Int(local * sampleRate) + index * 997, 77) * 2 - 1
                    value += noise * 0.05 * exp(-local * 240)
                }
                return value
            }
        }
        let notes = notes(for: cue)
        let length = (notes.map { $0.start + $0.duration }.max() ?? 0.2) + 0.25
        return render(length: length, sampleRate: sampleRate) { t in
            var value = 0.0
            for note in notes {
                let local = t - note.start
                guard local >= 0 else { continue }
                // Fast attack, exponential decay: a soft bell.
                let attack = min(1, local / 0.006)
                let decay = exp(-local * (3.2 / note.duration))
                let phase = 2 * .pi * note.frequency * local
                let tone = sin(phase) + 0.28 * sin(2 * phase) + 0.08 * sin(3.01 * phase)
                value += tone * attack * decay * note.amplitude
            }
            return value
        }
    }

    private func render(length: Double, sampleRate: Double, sample: (Double) -> Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(length * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            let t = Double(index) / sampleRate
            // Short fade-out at the very end to avoid clicks.
            let tail = min(1, (length - t) / 0.02)
            channel[index] = Float(max(-1, min(1, sample(t) * tail)))
        }
        return buffer
    }
}
