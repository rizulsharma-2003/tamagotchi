import Foundation

/// Something Mochi can do on the spot, without asking Claude.
public enum QuickCommand: Equatable, Sendable {
    case media(MediaKey)
    case volume(VolumeChange)
    /// A focus session; nil minutes means the usual length.
    case focus(minutes: Int?)
    case stopFocus
    case explore
    case comeHome
    case interact(PetInteraction)
    case games
    case recap
    case decorate
    case sessionsStatus
    /// What needs you in Gmail, Calendar and Notion (Mochi's agent).
    case agentNews
    /// An installed app, by its name as installed.
    case openApp(String)
    /// A running app to bring forward.
    case switchToApp(String)
    case openSite(URL)
}

public enum MediaKey: String, Sendable, Equatable {
    case playPause, next, previous
}

public enum VolumeChange: Equatable, Sendable {
    case up, down, mute, unmute
    case set(Int)
}

/// What the parser may match app names against.
public struct QuickCommandContext: Sendable {
    public var installedApps: [String]
    public var runningApps: [String]

    public init(installedApps: [String] = [], runningApps: [String] = []) {
        self.installedApps = installedApps
        self.runningApps = runningApps
    }
}

/// Recognizes short, unambiguous commands ("pause the music", "volume to 30", "25 minute focus",
/// "go explore", "open Slack"). Precision over recall: anything it is unsure about goes to Claude.
public enum QuickCommands {
    public static func parse(_ text: String, context: QuickCommandContext = QuickCommandContext()) -> QuickCommand? {
        let s = normalize(text)
        guard !s.isEmpty else { return nil }
        if let command = fixed[s] { return command }

        if let match = s.wholeMatch(of: /(?:set |turn )?(?:the )?volume (?:to |at )?(\d{1,3})(?: ?%| percent)?/) {
            return .volume(.set(min(100, Int(match.1) ?? 50)))
        }
        if let match = s.wholeMatch(of: /(?:start |begin )?(?:a |an )?(\d{1,3})[ -]?(?:min|mins|minute|minutes)(?: of)?(?: focus| focus session| focus timer| focusing| pomodoro| timer)/) {
            return .focus(minutes: clampMinutes(match.1))
        }
        if let match = s.wholeMatch(of: /(?:start )?(?:a )?(?:focus|focusing|pomodoro)(?: session| timer)?(?: for)? (\d{1,3}) ?(?:min|mins|minute|minutes)/) {
            return .focus(minutes: clampMinutes(match.1))
        }
        if s.wholeMatch(of: /(?:what|how)(?:'s| is| are)? (?:my |the |all )?(?:claude|claudes|claude sessions?|sessions)(?: doing| up to| going)?/) != nil {
            return .sessionsStatus
        }
        if let match = s.wholeMatch(of: /(?:open|launch|start|run) (.+)/) {
            let target = String(match.1)
            if let app = matchApp(target, in: context.installedApps) { return .openApp(app) }
            if let url = site(target) { return .openSite(url) }
            return nil
        }
        if let match = s.wholeMatch(of: /(?:go to|switch to|bring up|show me|show|focus on|jump to) (.+)/) {
            let target = String(match.1)
            if let app = matchApp(target, in: context.runningApps) { return .switchToApp(app) }
            if let app = matchApp(target, in: context.installedApps) { return .openApp(app) }
            return nil
        }
        return nil
    }

    /// Lowercased, punctuation and wake words ("hey Mochi,") and politeness ("please") removed.
    public static func normalize(_ text: String) -> String {
        var s = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        s = String(s.map { $0.isLetter || $0.isNumber || "'%-.".contains($0) ? $0 : " " })
        s = s.split(separator: " ").joined(separator: " ")
        while s.hasSuffix(".") { s.removeLast() }
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where s == prefix || s.hasPrefix(prefix + " ") {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
            for suffix in suffixes where s.hasSuffix(" " + suffix) {
                s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return s
    }

    /// The installed or running app a spoken name refers to ("vs code" → "Visual Studio Code").
    public static func matchApp(_ query: String, in names: [String]) -> String? {
        var q = query
        for prefix in ["the ", "my "] where q.hasPrefix(prefix) { q = String(q.dropFirst(prefix.count)) }
        for suffix in [" app", " application", " window", " windows"] where q.hasSuffix(suffix) { q = String(q.dropLast(suffix.count)) }
        let wanted = key(aliases[q] ?? q)
        guard !wanted.isEmpty else { return nil }
        return names.first { key($0) == wanted }
    }

    static func site(_ target: String) -> URL? {
        var t = target
        for prefix in ["the ", "my "] where t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        for suffix in [" website", " site", " web site"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        if let known = sites[t] { return URL(string: known) }
        if t.wholeMatch(of: /[a-z0-9-]+(?:\.[a-z0-9-]+)+/) != nil, let tld = t.split(separator: ".").last, tld.count >= 2 {
            return URL(string: "https://\(t)")
        }
        return nil
    }

    private static func key(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    private static func clampMinutes(_ text: Substring) -> Int {
        max(1, min(180, Int(text) ?? 25))
    }

    private static let prefixes = [
        "hey mochi", "hi mochi", "ok mochi", "okay mochi", "yo mochi", "hey motchi", "mochi", "motchi", "mochie",
        "please", "can you please", "could you please", "can you", "could you", "would you", "will you",
        "i want you to", "go ahead and",
    ]
    private static let suffixes = ["please", "for me", "thanks", "thank you", "mochi", "motchi", "now"]

    private static let aliases: [String: String] = [
        "vs code": "Visual Studio Code", "vscode": "Visual Studio Code", "code": "Visual Studio Code",
        "chrome": "Google Chrome", "settings": "System Settings", "system preferences": "System Settings",
        "iterm": "iTerm", "word": "Microsoft Word", "excel": "Microsoft Excel", "powerpoint": "Microsoft PowerPoint",
        "teams": "Microsoft Teams", "outlook": "Microsoft Outlook",
    ]

    private static let sites: [String: String] = [
        "youtube": "https://www.youtube.com", "gmail": "https://mail.google.com", "google": "https://www.google.com",
        "github": "https://github.com", "google maps": "https://maps.google.com", "google drive": "https://drive.google.com",
        "google calendar": "https://calendar.google.com", "google docs": "https://docs.google.com",
        "twitter": "https://x.com", "x": "https://x.com", "reddit": "https://www.reddit.com",
        "netflix": "https://www.netflix.com", "linkedin": "https://www.linkedin.com", "instagram": "https://www.instagram.com",
        "wikipedia": "https://www.wikipedia.org", "claude": "https://claude.ai", "chatgpt": "https://chatgpt.com",
    ]

    private static let fixed: [String: QuickCommand] = {
        var table: [String: QuickCommand] = [:]
        func add(_ command: QuickCommand, _ phrases: [String]) { for phrase in phrases { table[phrase] = command } }
        add(.media(.playPause), [
            "pause", "pause it", "pause music", "pause the music", "pause the song", "pause the video", "pause playback",
            "stop the music", "stop music", "stop the song", "stop the video", "play", "play music", "play the music",
            "resume", "resume music", "resume the music", "resume playing", "continue playing", "unpause", "play pause",
        ])
        add(.media(.next), ["next", "next song", "next track", "skip", "skip song", "skip this song", "skip track",
                            "skip this", "play the next song", "next video"])
        add(.media(.previous), ["previous", "previous song", "previous track", "last song", "go back a song",
                                "play the previous song", "play the last song"])
        add(.volume(.up), ["volume up", "turn the volume up", "turn volume up", "turn up the volume", "turn it up",
                           "louder", "increase the volume", "increase volume", "raise the volume"])
        add(.volume(.down), ["volume down", "turn the volume down", "turn volume down", "turn down the volume",
                             "turn it down", "quieter", "softer", "lower the volume", "decrease the volume", "decrease volume"])
        add(.volume(.mute), ["mute", "mute the sound", "mute sound", "mute the volume", "mute volume", "mute the mac"])
        add(.volume(.unmute), ["unmute", "unmute the sound", "unmute sound", "unmute the mac"])
        add(.focus(minutes: nil), ["focus", "start focus", "start focusing", "start a focus session", "start focus session",
                                   "focus session", "focus mode", "start a pomodoro", "pomodoro", "start pomodoro",
                                   "let's focus", "lets focus", "help me focus"])
        add(.stopFocus, ["stop focus", "stop focusing", "stop the focus session", "stop focus session", "end focus",
                         "end the focus session", "cancel focus", "stop the timer", "stop timer", "stop pomodoro",
                         "stop the pomodoro", "end the pomodoro"])
        add(.explore, ["explore", "go explore", "go exploring", "explore the desktop", "go for a walk", "take a walk",
                       "go on an adventure", "adventure", "go play on the desktop"])
        add(.comeHome, ["come home", "come back", "come back home", "go home", "come back to the menu bar", "home"])
        add(.interact(.pet), ["pet", "purr", "good kitty", "good cat", "good girl", "good boy", "i love you", "love you",
                              "who's a good cat", "who's a good kitty"])
        add(.interact(.play), ["play with me", "let's play", "lets play", "wanna play", "want to play"])
        add(.interact(.treat), ["treat", "have a treat", "eat", "eat something", "feed", "feed yourself", "snack",
                                "have a snack", "dinner time", "food", "are you hungry"])
        add(.games, ["games", "open games", "play a game", "let's play a game", "lets play a game", "show games"])
        add(.recap, ["recap", "show recap", "show me the recap", "today's recap", "todays recap", "show today's recap",
                     "daily recap", "what did i do today", "how was my day"])
        add(.decorate, ["decorate", "decorate the room", "room makeover", "edit the room", "redecorate"])
        add(.sessionsStatus, ["status", "claude status", "sessions", "my sessions", "show my claude sessions",
                              "show my sessions", "list my claude sessions"])
        add(.agentNews, ["what's pending", "whats pending", "what is pending", "anything pending", "what's new", "whats new",
                         "anything new", "check my email", "check my mail", "check my inbox", "check email", "any new email",
                         "any new emails", "any new mail", "summarize my email", "summarise my email", "summarize my unread",
                         "summarise my unread", "summarize my inbox", "summarise my inbox", "what's on my calendar",
                         "whats on my calendar", "what do i have today", "what's on today", "whats on today", "briefing",
                         "my briefing", "morning briefing", "give me my briefing", "what needs me", "what needs my attention"])
        return table
    }()
}
