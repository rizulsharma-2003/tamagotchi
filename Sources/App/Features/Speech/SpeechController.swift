import AppKit
import SwiftUI
import TamagotchiCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Mochi talks: short speech bubbles for greetings, real Claude events and sleepy mumbles.
/// Lines are hand-written; with Apple Intelligence on, a few fresh ones are written on this Mac
/// now and then (from the kind of moment only — never projects, files or anything typed).
@MainActor
final class SpeechController {
    private unowned let environment: AppEnvironment
    private var world: CompanionWorld { environment.world }
    private var timer: Timer?
    /// Keeps a menu-bar bubble over a roaming pet while it shows.
    private var followTimer: Timer?
    private let panel = MenuBarSpeechPanel()
    private var lastSpokeAt: TimeInterval = -.infinity
    private var recent: [String] = []
    private var rng = SystemRandomNumberGenerator()
    private var greeted: String?
    private var nextIdleAt: TimeInterval?
    private var nextSleepAt: TimeInterval?
    private var wasAsleep = false
    private var lastCheck: TimeInterval = 0
    private var fresh: [SpeechOccasion: [SpeechLines.Line]] = [:]
    private var lastRefill: Date?
    private var writing = false

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func start() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wasAsleep = world.petAsleep
        environment.debug.register("say") { [weak self] argument in
            guard let self else { return }
            if let occasion = SpeechOccasion(rawValue: argument) {
                self.lastSpokeAt = -.infinity
                self.say(occasion)
            } else {
                self.world.say(argument)
            }
        }
        environment.debug.registerState("speech") { [weak self] in
            guard let self, let bubble = self.world.speech else { return NSNull() }
            return ["text": bubble.text, "speaker": bubble.speaker.rawValue, "menuBar": self.panel.isShowing,
                    "freshLines": self.fresh.values.reduce(0) { $0 + $1.count }]
        }
    }

    // MARK: Triggers

    func react(to event: CompanionEvent, session: SessionSnapshot?) {
        guard let occasion = SpeechOccasion.forEvent(event) else { return }
        // Background sessions only speak up for what really matters.
        if let session, let primary = world.primarySession, session.id != primary.id, occasion.importance < .high { return }
        say(occasion)
    }

    func interacted(_ kind: PetInteraction) {
        let occasion: SpeechOccasion = kind == .pet ? .petted : (kind == .play ? .played : .treat)
        guard Double.random(in: 0..<1, using: &rng) < 0.65 else { return }
        say(occasion)
    }

    private func say(_ occasion: SpeechOccasion) {
        let settings = world.settings
        guard settings.speech.enabled, !settings.pauseReactions else { return }
        let now = world.now
        guard SpeechPacing(chattiness: settings.speech.chattiness).allows(occasion, since: now - lastSpokeAt) else { return }
        guard let line = freshLine(for: occasion) ?? SpeechLines.pick(occasion, seed: UInt64.random(in: 0...UInt64.max, using: &rng), avoiding: recent) else {
            return
        }
        if line.speaker == .companion, !world.companionPresent { return }
        if line.speaker == .pet, world.adventureActive { return }
        lastSpokeAt = now
        recent.append(line.text)
        if recent.count > 8 { recent.removeFirst() }
        let duration = min(6, max(3.2, 2 + Double(line.text.count) * 0.11))
        world.say(line.text, speaker: line.speaker, duration: duration)
    }

    // MARK: Ticking

    private func tick() {
        let now = world.now
        if let bubble = world.speech, !bubble.isVisible(at: now) {
            world.clearSpeech(id: bubble.id)
        }
        updatePanel()
        guard now - lastCheck >= 5 else { return }
        lastCheck = now
        spontaneous(now: now)
        refillFreshLines()
    }

    private func spontaneous(now: TimeInterval) {
        let settings = world.settings
        guard settings.speech.enabled, !settings.pauseReactions else { return }
        let pacing = SpeechPacing(chattiness: settings.speech.chattiness)
        let date = Date()
        // Greet once per part of the day, when the user is clearly here (the panel is open).
        let occasion = SpeechOccasion.greeting(hour: Calendar.current.component(.hour, from: date))
        let period = "\(Calendar.current.startOfDay(for: date).timeIntervalSince1970)-\(occasion.rawValue)"
        if environment.ui.popoverVisible, greeted != period {
            greeted = period
            lastSpokeAt = -.infinity
            say(occasion)
            return
        }
        if wasAsleep, !world.petAsleep, Bool.random(using: &rng) { say(.wokeUp) }
        wasAsleep = world.petAsleep
        let working = world.menuBarStatus.companionWorking
        if world.petAsleep, let interval = pacing.sleepInterval {
            if let next = nextSleepAt, now >= next { say(.sleepy) }
            if nextSleepAt == nil || now >= nextSleepAt! { nextSleepAt = now + interval * Double.random(in: 0.7...1.3, using: &rng) }
        } else if !working, let interval = pacing.idleInterval {
            if let next = nextIdleAt, now >= next { say(.idle) }
            if nextIdleAt == nil || now >= nextIdleAt! { nextIdleAt = now + interval * Double.random(in: 0.7...1.3, using: &rng) }
        }
    }

    // MARK: Menu bar

    /// While the panel is closed, bubbles hang just under the menu bar, pointing at the speaker.
    private func updatePanel() {
        guard let bubble = world.speech, bubble.isVisible(at: world.now), !environment.ui.popoverVisible,
              let target = speakerPoint(bubble.speaker) else {
            panel.hide()
            followTimer?.invalidate()
            followTimer = nil
            return
        }
        panel.show(bubble, pointingAt: target.x, belowY: target.y, screen: target.screen)
        if followTimer == nil, bubble.speaker == .pet, world.roamer.isActive {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePanel() }
            }
            RunLoop.main.add(timer, forMode: .common)
            followTimer = timer
        }
    }

    private func speakerPoint(_ speaker: SpeechSpeaker) -> (x: CGFloat, y: CGFloat, screen: NSScreen)? {
        guard let item = environment.statusItem.buttonScreenFrame,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: item.midX, y: item.midY)) }) else { return nil }
        let bottom = min(item.minY, screen.visibleFrame.maxY)
        let roamer = world.roamer
        guard environment.statusItem.overlay != nil, roamer.isActive, let zone = roamer.zone,
              NSApp.userInterfaceLayoutDirection == .leftToRight else {
            return (item.midX, bottom, screen)
        }
        if speaker == .companion { return (CGFloat(zone.companionX), bottom, screen) }
        if world.adventureActive { return nil }
        return (CGFloat(roamer.sample(at: world.now).x), bottom, screen)
    }

    // MARK: Fresh lines from Apple Intelligence

    private static let freshOccasions: [SpeechOccasion] = [
        .morning, .afternoon, .evening, .lateNight, .sessionStarted, .turnCompleted, .testsPassed,
        .waitingForUser, .petted, .played, .treat, .sleepy, .idle,
    ]

    private func freshLine(for occasion: SpeechOccasion) -> SpeechLines.Line? {
        guard world.settings.speech.useAppleIntelligence, var lines = fresh[occasion], !lines.isEmpty,
              Bool.random(using: &rng) else { return nil }
        let line = lines.removeFirst()
        fresh[occasion] = lines
        return line
    }

    /// Asks the on-device model for a handful of new lines every couple of hours.
    private func refillFreshLines() {
        let settings = world.settings.speech
        guard settings.enabled, settings.useAppleIntelligence, !writing else { return }
        if let lastRefill, Date().timeIntervalSince(lastRefill) < 2 * 3600 { return }
        lastRefill = Date()
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return }
            writing = true
            let names = (pet: world.settings.petName, companion: world.settings.companionName)
            Task { [weak self] in
                let lines = await FreshLineWriter.write(Self.freshOccasions, petName: names.pet, companionName: names.companion)
                guard let self else { return }
                for (occasion, new) in lines {
                    self.fresh[occasion] = Array((self.fresh[occasion] ?? []) + new).suffix(3)
                }
                self.writing = false
            }
        }
        #endif
    }

    /// Whether this Mac can write fresh lines (Apple Intelligence available and on).
    static var appleIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
enum FreshLineWriter {
    static func write(_ occasions: [SpeechOccasion], petName: String, companionName: String) async -> [SpeechOccasion: [SpeechLines.Line]] {
        var result: [SpeechOccasion: [SpeechLines.Line]] = [:]
        for occasion in occasions {
            let speaker = SpeechLines.lines(for: occasion).first?.speaker ?? .pet
            let persona = speaker == .pet
                ? "You are \(petName), a playful, affectionate little cat who lives in the Mac menu bar."
                : "You are \(companionName), a cheerful little pixel-art creature who helps people write code."
            let session = LanguageModelSession(instructions: persona
                + " Reply with one very short, warm, playful line of at most eight words, said out loud in a speech bubble."
                + " No quotes, no hashtags, no names.")
            do {
                let response = try await session.respond(to: "\(occasion.situation) What do you say?",
                                                         options: GenerationOptions(temperature: 0.9, maximumResponseTokens: 24))
                if let text = SpeechLines.sanitize(response.content) {
                    result[occasion, default: []].append(SpeechLines.Line(speaker: speaker, text: text))
                }
            } catch {
                continue
            }
        }
        return result
    }
}
#endif

/// A borderless bubble window just under the menu bar.
@MainActor
final class MenuBarSpeechPanel {
    private var panel: NSPanel?
    private var host: NSHostingView<MenuBarBubble>?
    private var shownID: Int?
    private(set) var isShowing = false

    func show(_ bubble: SpeechBubble, pointingAt x: CGFloat, belowY y: CGFloat, screen: NSScreen) {
        let panel = panel ?? makePanel()
        self.panel = panel
        if shownID != bubble.id || host == nil {
            shownID = bubble.id
            let host = NSHostingView(rootView: MenuBarBubble(text: bubble.text, tailOffset: 0))
            panel.contentView = host
            self.host = host
        }
        guard let host else { return }
        let size = host.fittingSize
        let visible = screen.visibleFrame
        let left = min(max(x - size.width / 2, visible.minX + 4), visible.maxX - size.width - 4)
        let offset = (x - (left + size.width / 2)).rounded()
        if host.rootView.tailOffset != offset {
            host.rootView = MenuBarBubble(text: bubble.text, tailOffset: offset)
        }
        panel.setFrame(CGRect(x: left.rounded(), y: (y - size.height + 3).rounded(), width: size.width, height: size.height), display: false)
        if !isShowing {
            panel.orderFrontRegardless()
            isShowing = true
        }
    }

    func hide() {
        guard isShowing else { return }
        panel?.orderOut(nil)
        isShowing = false
        shownID = nil
        host = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        return panel
    }
}

struct MenuBarBubble: View {
    let text: String
    let tailOffset: CGFloat

    var body: some View {
        SpeechBubbleView(text: text, tailEdge: .top, tailOffset: tailOffset, opaque: true)
            .padding(6)
    }
}
