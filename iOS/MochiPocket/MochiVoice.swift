import AVFoundation

/// How Mochi sounds when it reads to you: its natural voice (Kokoro, `KokoroVoice`) once that's downloaded, or one
/// of this iPhone's voices made Mochi's own by a character (pitch and pace). It all happens on the iPhone; nothing
/// is sent anywhere. Siri's own voice isn't open to apps, so when you ask Siri "What's waiting", either Mochi reads
/// it in this voice or Siri reads it in Siri's (`siriReadsKey`).
struct MochiVoice: Equatable {
    var character: Character
    /// The iPhone voice it starts from; nil picks the best one installed for your language.
    var voiceID: String?
    /// Read with Kokoro (falling back to the iPhone voice when it can't).
    var natural = false
    var style = KokoroVoice.Style.current

    enum Character: String, CaseIterable, Identifiable {
        case mochi, tiny, calm, plain

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mochi: "Mochi"
            case .tiny: "Tiny"
            case .calm: "Calm"
            case .plain: "Plain"
            }
        }

        var blurb: String {
            switch self {
            case .mochi: "Bright and a little higher: Mochi's own voice."
            case .tiny: "Small and squeaky, like a pet that fits in your pocket."
            case .calm: "A little lower and unhurried."
            case .plain: "The iPhone voice just as it is."
            }
        }

        /// Pitch change in cents (100 is a semitone).
        var cents: Float {
            switch self {
            case .mochi: 350
            case .tiny: 700
            case .calm: -150
            case .plain: 0
            }
        }

        /// Speaking pace, relative to the voice's usual pace.
        var pace: Float {
            switch self {
            case .mochi: 1.04
            case .tiny: 1.08
            case .calm: 0.92
            case .plain: 1
            }
        }
    }

    static let characterKey = "mochiVoiceCharacter"
    static let voiceKey = "mochiVoiceID"
    /// On: Siri reads "What's waiting" in Siri's voice. Off (the default): Mochi reads it in its own.
    static let siriReadsKey = "siriReadsUpdates"

    /// The voice set in Settings.
    static var current: MochiVoice {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: voiceKey) ?? ""
        return MochiVoice(character: Character(rawValue: defaults.string(forKey: characterKey) ?? "") ?? .mochi,
                          voiceID: id.isEmpty ? nil : id, natural: KokoroVoice.inUse, style: .current)
    }

    /// The chosen voice while it's installed, else the best one for your language.
    var base: AVSpeechSynthesisVoice? {
        if let voiceID, let chosen = AVSpeechSynthesisVoice(identifier: voiceID) { return chosen }
        return Self.automatic()
    }

    func utterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = base
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * character.pace
        utterance.postUtteranceDelay = 0.1
        return utterance
    }

    /// The best voice for this iPhone's language: a downloaded Premium or Enhanced one (your own accent first), else
    /// the language's standard voice. Never a Personal Voice unless you pick it.
    static func automatic() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let better = choices().filter { $0.quality != .default && !$0.voiceTraits.contains(.isPersonalVoice) }
        return better.first ?? AVSpeechSynthesisVoice(language: language)
    }

    /// Voices for this iPhone's language, best first: Personal Voices, then Premium, Enhanced and standard (your own
    /// accent first within each). Novelty voices (bells, bubbles) are left out.
    static func choices() -> [AVSpeechSynthesisVoice] {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let family = String(language.prefix(2))
        func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
            var score = voice.voiceTraits.contains(.isPersonalVoice) ? 1000 : 0
            switch voice.quality {
            case .premium: score += 300
            case .enhanced: score += 200
            default: score += 100
            }
            if voice.language == language { score += 10 }
            return score
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(family) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { rank($0) != rank($1) ? rank($0) > rank($1) : $0.name < $1.name }
    }

    /// "Ava · Premium · English (US)".
    static func label(_ voice: AVSpeechSynthesisVoice) -> String {
        var parts = [voice.name]
        if voice.voiceTraits.contains(.isPersonalVoice) {
            parts.append("Personal Voice")
        } else if voice.quality == .premium {
            parts.append("Premium")
        } else if voice.quality == .enhanced {
            parts.append("Enhanced")
        }
        if let place = Locale.current.localizedString(forIdentifier: voice.language) { parts.append(place) }
        return parts.joined(separator: " · ")
    }
}
