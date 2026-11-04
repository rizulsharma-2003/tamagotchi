import AVFoundation
import Observation
import TamagotchiCore

/// Reads "Waiting for you" out loud with this iPhone's own voice (nothing leaves the phone). A second tap stops it.
@MainActor
@Observable
final class UpdatesReader: NSObject {
    static let shared = UpdatesReader()

    private(set) var speaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ items: [AgentNote]) {
        if speaking {
            synthesizer.stopSpeaking(at: .immediate)
            return
        }
        // Spoken audio plays even with the ring switch on silent, and other sound dips while Mochi talks.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: AgentSpeech.script(items: items))
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.postUtteranceDelay = 0.1
        speaking = true
        synthesizer.speak(utterance)
    }

    /// Reads the list from the start (Siri's "What's waiting"), after `delay` seconds so Siri can finish talking.
    func speak(_ items: [AgentNote], after delay: TimeInterval = 0) {
        if speaking { synthesizer.stopSpeaking(at: .immediate) }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: AgentSpeech.script(items: items))
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.preUtteranceDelay = delay
        utterance.postUtteranceDelay = 0.1
        speaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        if speaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    fileprivate func finished() {
        speaking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension UpdatesReader: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
}
