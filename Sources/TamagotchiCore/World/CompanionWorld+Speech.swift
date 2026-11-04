import Foundation

extension CompanionWorld {
    /// Shows a short speech bubble for one of the characters.
    public func say(_ text: String, speaker: SpeechSpeaker = .pet, duration: TimeInterval = 4.5) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, settings.speech.enabled else { return }
        speech = SpeechBubble(id: (speech?.id ?? 0) + 1, text: trimmed, speaker: speaker, startedAt: now, duration: duration)
    }

    /// Removes the bubble once it has had its time (only that bubble, not a newer one).
    public func clearSpeech(id: Int) {
        if speech?.id == id { speech = nil }
    }

    /// The bubble that should be on screen now, if any.
    public var activeSpeech: SpeechBubble? {
        guard let speech, speech.isVisible(at: now) else { return nil }
        return speech
    }
}
