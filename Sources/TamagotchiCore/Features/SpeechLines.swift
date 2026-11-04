import Foundation

/// Moments the characters may say something about.
public enum SpeechOccasion: String, Sendable, CaseIterable {
    case morning, afternoon, evening, lateNight
    case sessionStarted, promptSubmitted, turnCompleted, turnFailed, toolFailed
    case buildPassed, testsPassed, buildFailed, testsFailed
    case waitingForUser, permission, subagentStarted, sessionEnded
    case petted, played, treat, wokeUp, sleepy, idle

    /// How much a line here matters: quiet chattiness keeps only `.high`.
    public enum Importance: Int, Sendable, Comparable {
        case low, medium, high
        public static func < (a: Importance, b: Importance) -> Bool { a.rawValue < b.rawValue }
    }

    public var importance: Importance {
        switch self {
        case .waitingForUser, .permission, .turnCompleted, .buildPassed, .testsPassed: return .high
        case .promptSubmitted, .sleepy, .idle: return .low
        default: return .medium
        }
    }

    /// What happened, in plain words, for asking an on-device model for a fresh line.
    /// Never mentions projects, files, commands or anything the user typed.
    public var situation: String {
        switch self {
        case .morning: return "It is morning and the user just showed up."
        case .afternoon: return "It is the afternoon."
        case .evening: return "It is the evening."
        case .lateNight: return "It is very late at night and the user is still at the computer."
        case .sessionStarted: return "Claude, the coding assistant, just started a work session."
        case .promptSubmitted: return "The user just gave Claude a new task."
        case .turnCompleted: return "Claude just finished a task."
        case .turnFailed: return "Claude's task stopped with an error."
        case .toolFailed: return "One of Claude's steps hit an error, and Claude keeps working."
        case .buildPassed: return "The build just passed."
        case .testsPassed: return "All the tests just passed."
        case .buildFailed: return "The build just failed."
        case .testsFailed: return "Some tests just failed."
        case .waitingForUser: return "Claude is waiting for the user to answer a question."
        case .permission: return "Claude is asking the user for permission to continue."
        case .subagentStarted: return "Claude just called in helper agents."
        case .sessionEnded: return "Claude's work session just ended."
        case .petted: return "The user is petting the cat."
        case .played: return "The user is playing with the cat."
        case .treat: return "The user just gave the cat a treat."
        case .wokeUp: return "The cat just woke up from a nap."
        case .sleepy: return "The cat is asleep, mumbling in its dreams."
        case .idle: return "Nothing is happening; the cat is just hanging around."
        }
    }

    /// The occasion for a real Claude Code event, if it deserves a word.
    public static func forEvent(_ event: CompanionEvent) -> SpeechOccasion? {
        if let outcome = event.buildTestOutcome {
            switch (outcome.kind, outcome.passed) {
            case (.build, true): return .buildPassed
            case (.test, true): return .testsPassed
            case (.build, false): return .buildFailed
            case (.test, false): return .testsFailed
            }
        }
        switch event.kind {
        case .sessionStarted: return .sessionStarted
        case .promptSubmitted: return .promptSubmitted
        case .toolFailed: return event.interrupted ? nil : .toolFailed
        case .permissionRequested: return .permission
        case .attentionNeeded: return event.attention == .permission ? .permission : .waitingForUser
        case .subagentStarted: return .subagentStarted
        case .turnCompleted: return .turnCompleted
        case .turnFailed: return .turnFailed
        case .sessionEnded: return .sessionEnded
        default: return nil
        }
    }

    public static func greeting(hour: Int) -> SpeechOccasion {
        switch hour {
        case 5..<12: return .morning
        case 12..<17: return .afternoon
        case 17..<23: return .evening
        default: return .lateNight
        }
    }
}

/// Hand-written lines for every occasion: the pet is bubbly, the companion a focused little engineer.
public enum SpeechLines {
    public struct Line: Sendable, Equatable {
        public var speaker: SpeechSpeaker
        public var text: String

        public init(speaker: SpeechSpeaker, text: String) {
            self.speaker = speaker
            self.text = text
        }
    }

    public static func lines(for occasion: SpeechOccasion) -> [Line] {
        func pet(_ texts: String...) -> [Line] { texts.map { Line(speaker: .pet, text: $0) } }
        func claude(_ texts: String...) -> [Line] { texts.map { Line(speaker: .companion, text: $0) } }
        switch occasion {
        case .morning: return pet("Good morning! ☀️", "Morning! Coffee first?", "Rise and shine!", "Ready for a good day?")
        case .afternoon: return pet("Good afternoon!", "Snack o'clock?", "Halfway there!", "Afternoon stretch? 🐾")
        case .evening: return pet("Good evening!", "Cozy evening coding?", "Don't forget dinner!", "Evening already?")
        case .lateNight: return pet("It's late… bed soon?", "Night owl mode 🦉", "Yawn… still coding?", "The stars are out ✨")
        case .sessionStarted: return pet("Claude's here!", "Yay, Claude!") + claude("Hi! Ready when you are.", "Let's build something.", "Booting up… hello!")
        case .promptSubmitted: return claude("On it!", "Ooh, a new task.", "Let me think…", "Reading the request…")
        case .turnCompleted: return pet("Claude's done, high five!", "Done! 🎉", "Nice work!") + claude("All done!", "Finished! ✨", "Ta-da!")
        case .turnFailed: return claude("Hmm, that didn't work.", "Let me try another way.") + pet("We'll get it next time!")
        case .toolFailed: return claude("Oops, an error.", "Hmm… not quite.", "Let me fix that.")
        case .buildPassed: return pet("Green build! 💚") + claude("Build passed!", "It compiles! ✨")
        case .testsPassed: return pet("All tests pass! ✅", "Green across the board!") + claude("Tests are green!")
        case .buildFailed: return claude("Build's broken… on it.", "Red build. Fixing!") + pet("You've got this!")
        case .testsFailed: return claude("Red tests… on it.", "A test failed. Looking.") + pet("Don't worry, we've got this.")
        case .waitingForUser: return pet("Claude needs you!", "Psst… your turn!", "Claude has a question.")
        case .permission: return claude("May I? Need your OK.", "Waiting for your approval.") + pet("Claude's asking permission!")
        case .subagentStarted: return claude("Calling in helpers!", "Teamwork time!", "Mini-me's, assemble!")
        case .sessionEnded: return claude("See you soon!", "Bye for now! 👋") + pet("Bye, Claude!")
        case .petted: return pet("Purr…", "Hehe, that tickles!", "More scritches?", "♥ ♥ ♥", "Mrrrp!")
        case .played: return pet("Again! Again!", "Catch me!", "Wheee!", "Best game ever!")
        case .treat: return pet("Yum!", "Nom nom nom", "My favourite!", "Thank you! ♥")
        case .wokeUp: return pet("Oh! I'm awake!", "Was I snoring?", "Did I miss anything?")
        case .sleepy: return pet("zzz… cookies…", "five more minutes…", "mmm… yarn…", "zzz…", "…tuna…")
        case .idle: return pet("I wonder what Claude's building.", "Is it snack time?", "La la la ♪", "Pet me? 👀", "*stretches*")
        }
    }

    /// A line for the occasion, not one of the `recent` ones when there is a choice.
    public static func pick(_ occasion: SpeechOccasion, seed: UInt64, avoiding recent: [String] = []) -> Line? {
        let all = lines(for: occasion)
        let fresh = all.filter { !recent.contains($0.text) }
        let pool = fresh.isEmpty ? all : fresh
        guard !pool.isEmpty else { return nil }
        var mixer = seed &+ 0x9E37_79B9_7F4A_7C15
        mixer = (mixer ^ (mixer >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixer = (mixer ^ (mixer >> 27)) &* 0x94D0_49BB_1331_11EB
        return pool[Int((mixer ^ (mixer >> 31)) % UInt64(pool.count))]
    }

    /// Cleans a generated line: one short sentence, no quotes, nothing that sounds like a refusal.
    public static func sanitize(_ raw: String, maxLength: Int = 44) -> String? {
        var text = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’*")))
        let lowered = text.lowercased()
        let refusals = ["sorry", "as an ai", "i can't", "i cannot", "language model", "assistant"]
        guard !text.isEmpty, !refusals.contains(where: lowered.contains) else { return nil }
        if text.count > maxLength {
            let cut = text.prefix(maxLength)
            guard let space = cut.lastIndex(of: " ") else { return nil }
            text = String(cut[..<space]).trimmingCharacters(in: .punctuationCharacters) + "…"
        }
        return text
    }
}

/// When a line may be said: each chattiness level has its own pace; important lines get through sooner.
public struct SpeechPacing: Sendable {
    public var chattiness: Chattiness

    public init(chattiness: Chattiness) {
        self.chattiness = chattiness
    }

    /// Whether `occasion` may speak `since` seconds after the last line.
    public func allows(_ occasion: SpeechOccasion, since: TimeInterval) -> Bool {
        let importance = occasion.importance
        switch chattiness {
        case .quiet:
            return importance == .high && since >= 20
        case .normal:
            if importance == .high { return since >= 8 }
            return since >= (importance == .medium ? 30 : 90)
        case .chatty:
            return since >= (importance == .high ? 5 : 12)
        }
    }

    /// Seconds between spontaneous idle musings (nil: never).
    public var idleInterval: TimeInterval? {
        switch chattiness {
        case .quiet: return nil
        case .normal: return 25 * 60
        case .chatty: return 9 * 60
        }
    }

    /// Seconds between sleepy mumbles while the pet naps (nil: never).
    public var sleepInterval: TimeInterval? {
        switch chattiness {
        case .quiet: return nil
        case .normal: return 7 * 60
        case .chatty: return 3 * 60
        }
    }
}
