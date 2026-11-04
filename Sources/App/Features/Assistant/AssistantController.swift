import AppKit
import AVFoundation
import Observation
import Security
import TamagotchiCore
import TamagotchiWire

/// Ask Mochi. Short requests Mochi does on the spot (`QuickCommands`); everything else goes to a
/// helper Claude session ("the brain") that acts through a fixed set of Mac actions ("paws") and
/// can message the user's other Claude sessions — each message only after the user approves it.
/// Nothing is written to disk: the conversation lives in memory until the brain is shut down.
@MainActor
@Observable
final class AssistantController {
    enum Phase: Equatable { case idle, listening, working, approving, done, failed }
    /// Where a request came from: typed or spoken here, or sent from Mochi Pocket on the iPhone.
    enum Origin: Equatable { case mac, phone(String) }
    enum StepState: Equatable { case running, done, failed }

    struct Step: Identifiable, Equatable {
        let id: String
        var symbol: String
        var text: String
        var state: StepState
    }

    /// A message the brain wants to send to another Claude session.
    struct Approval: Identifiable, Equatable {
        let id = UUID()
        var target: String
        var project: ProjectRef?
        var message: String
    }

    /// A request for one Claude session: a reply written on Mochi Pocket's session card or notification.
    struct Target: Equatable {
        var project: String
        var sessionID: String?
    }

    /// A prompt Mochi delivered, so it can say when that session finishes.
    private struct Delegation {
        var project: ProjectRef?
        var sentAt: Date
    }

    private(set) var phase: Phase = .idle
    private(set) var phaseChangedAt = Date()
    var draft = ""
    private(set) var request: String?
    private(set) var steps: [Step] = []
    private(set) var reply: String?
    private(set) var approval: Approval?
    /// What the microphone has heard so far while listening.
    private(set) var transcript = ""
    private(set) var panelVisible = false
    private(set) var shortcutProblem: String?
    /// Bumped to put the cursor back in the text field.
    private(set) var focusRequest = 0

    @ObservationIgnored private unowned let environment: AppEnvironment
    @ObservationIgnored private var brain: BrainSession?
    @ObservationIgnored private var brainStarting = false
    @ObservationIgnored private var pendingMessage: String?
    @ObservationIgnored private var approvalContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var previousApp: NSRunningApplication?
    @ObservationIgnored private var movedFocus = false
    /// Started from a development hook: never pops the panel up.
    @ObservationIgnored private var headless = false
    @ObservationIgnored private var origin: Origin = .mac
    @ObservationIgnored private var target: Target?
    @ObservationIgnored private var timeout: Timer?
    @ObservationIgnored private var idleShutdown: Timer?
    @ObservationIgnored private var holdTimer: Timer?
    @ObservationIgnored private var holding = false
    @ObservationIgnored private var delegations: [Delegation] = []
    /// Messages the user approved, by tool call, until Claude Code confirms delivery.
    @ObservationIgnored private var approvedMessages: [String: (project: ProjectRef?, at: Date)] = [:]
    @ObservationIgnored private var appNames: [String: String] = [:]
    @ObservationIgnored private let speaker = AVSpeechSynthesizer()
    @ObservationIgnored private lazy var panel = AskMochiPanel(controller: self, environment: environment)
    @ObservationIgnored private(set) lazy var voice = VoiceInput()
    @ObservationIgnored private lazy var paws: PawsServer = {
        let core = MCPServerCore(name: BrainLaunch.serverName, version: HelperInfo.version,
                                 instructions: "Mochi's hands on this Mac.", tools: Self.tools)
        return PawsServer(socketURL: environment.paths.pawsSocketFile, core: core) { [weak self] name, arguments in
            guard let self else { return ("Mochi is not running.", true) }
            return await self.performTool(name: name, arguments: arguments)
        }
    }()

    static let hotKeyID: UInt32 = 2
    private static let holdDelay: TimeInterval = 0.35
    private static let requestTimeout: TimeInterval = 120
    private static let idleShutdownDelay: TimeInterval = 10 * 60

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    private var world: CompanionWorld { environment.world }
    private var settings: AssistantSettings { environment.settingsStore.settings.assistant }
    var petName: String { environment.settingsStore.settings.petName }

    func start() {
        applySettings()
        registerDebugHooks()
    }

    func shutdown() {
        resolveApproval(false)
        brain?.terminate()
        brain = nil
        paws.stop()
        HotKey.unregister(id: Self.hotKeyID)
    }

    /// Registers the shortcut the settings ask for; called again when they change.
    func applySettings() {
        HotKey.unregister(id: Self.hotKeyID)
        shortcutProblem = nil
        guard settings.enabled, let combo = Self.combo(for: settings.shortcut) else {
            if !settings.enabled, panelVisible { hidePanel() }
            return
        }
        let registered = HotKey.register(id: Self.hotKeyID, combo: combo,
                                         onPress: { [weak self] in self?.shortcutPressed() },
                                         onRelease: { [weak self] in self?.shortcutReleased() })
        if !registered {
            shortcutProblem = "\(settings.shortcut.title) is already used by another app. Pick another shortcut."
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.shortcutProblem != nil else { return }
                self.world.say("My shortcut \(self.settings.shortcut.title) is taken — pick another in Settings › Assistant.", duration: 8)
            }
        }
    }

    static func combo(for shortcut: AssistantShortcut) -> HotKey.Combo? {
        switch shortcut {
        case .optionSpace: return HotKey.Combo(keyCode: 49, modifiers: UInt32(2048))            // kVK_Space, optionKey
        case .controlOptionSpace: return HotKey.Combo(keyCode: 49, modifiers: UInt32(2048 | 4096))
        case .controlOptionM: return HotKey.Combo(keyCode: 46, modifiers: UInt32(2048 | 4096))  // kVK_ANSI_M
        case .off: return nil
        }
    }

    // MARK: Shortcut: tap to type, hold to talk

    private func shortcutPressed() {
        holdTimer?.invalidate()
        holding = false
        guard settings.voice else {
            togglePanel()
            return
        }
        let timer = Timer(timeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.holding = true
                self.startListening()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func shortcutReleased() {
        holdTimer?.invalidate()
        holdTimer = nil
        guard settings.voice else { return }
        if holding {
            holding = false
            stopListening(submit: true)
        } else {
            togglePanel()
        }
    }

    // MARK: Panel

    func togglePanel() {
        panelVisible ? hidePanel() : showPanel()
    }

    func showPanel() {
        guard settings.enabled else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current { previousApp = front }
        if phase == .done || phase == .failed, Date().timeIntervalSince(phaseChangedAt) > 45 { clearConversationView() }
        panel.present()
        panelVisible = true
        focusRequest += 1
    }

    func hidePanel(restoreFocus: Bool = true) {
        if approval != nil { resolveApproval(false) }
        if phase == .listening { stopListening(submit: false) }
        guard panelVisible else { return }
        panel.orderOut(nil)
        panelVisible = false
        if restoreFocus, !movedFocus, NSApp.isActive, let previousApp, !previousApp.isTerminated {
            MacActions.bringForward(previousApp)
        }
    }

    /// Esc: decline, stop listening, cancel, then close.
    func escape() {
        switch phase {
        case .approving: decline()
        case .listening: stopListening(submit: false)
        case .working: cancelRequest()
        default: hidePanel()
        }
    }

    private func clearConversationView() {
        request = nil
        reply = nil
        steps = []
        setPhase(.idle)
    }

    private func setPhase(_ newPhase: Phase) {
        guard phase != newPhase else { return }
        phase = newPhase
        phaseChangedAt = Date()
    }

    // MARK: Requests

    func submit() {
        if phase == .approving {
            approve()
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        run(text)
    }

    func run(_ text: String, headless: Bool = false, spoken: Bool = false, origin: Origin = .mac, target: Target? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if phase == .working || phase == .approving {
            if case .phone(let commandID) = self.origin {
                environment.phone.reply(to: commandID, text: "I switched to your newer request.", ok: false)
            }
            stopCurrent()
        }
        self.headless = headless
        self.origin = origin
        self.target = target
        request = text
        reply = nil
        steps = []
        movedFocus = false
        setPhase(.working)
        idleShutdown?.invalidate()
        if let target {
            askBrain(BrainLaunch.directRequest(text, project: target.project), spoken: false)
            return
        }
        if let quick = QuickCommands.parse(text, context: quickContext()) {
            Task {
                let outcome = await perform(quick)
                guard self.request == text, self.phase == .working else { return }
                self.finish(outcome.text, ok: outcome.ok, movedFocus: outcome.movedFocus)
            }
            return
        }
        askBrain(text, spoken: spoken)
    }

    /// Stops what is running: declines a pending approval and stops the brain.
    func cancelRequest() {
        guard phase == .working || phase == .approving else { return }
        stopCurrent()
        finish("Okay, I stopped.", ok: false)
    }

    private func stopCurrent() {
        resolveApproval(false)
        timeout?.invalidate()
        pendingMessage = nil
        if let brain {
            brain.terminate()
            self.brain = nil
            paws.expect(token: nil)
        }
    }

    private func finish(_ text: String, ok: Bool, movedFocus moved: Bool = false) {
        timeout?.invalidate()
        for index in steps.indices where steps[index].state == .running { steps[index].state = ok ? .done : .failed }
        reply = text
        if moved { movedFocus = true }
        setPhase(ok ? .done : .failed)
        _ = world.playPet(ok ? .happyBounce : .confusedTilt)
        if !panelVisible || movedFocus || !NSApp.isActive { world.say(text, duration: 6) }
        if settings.spokenReplies { speak(text) }
        if case .phone(let commandID) = origin {
            environment.phone.reply(to: commandID, text: text, ok: ok)
            origin = .mac
        }
        if movedFocus, panelVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.phase == .done || self.phase == .failed else { return }
                self.hidePanel(restoreFocus: false)
            }
        }
        scheduleIdleShutdown()
    }

    private func speak(_ text: String) {
        speaker.stopSpeaking(at: .immediate)
        speaker.speak(AVSpeechUtterance(string: text))
    }

    // MARK: Quick commands

    private func quickContext() -> QuickCommandContext {
        QuickCommandContext(installedApps: Array(MacActions.installedApps().keys),
                            runningApps: MacActions.runningApps().compactMap(\.localizedName))
    }

    private func perform(_ command: QuickCommand) async -> MacActions.Outcome {
        switch command {
        case .media(let key): return MacActions.media(key)
        case .volume(let change): return MacActions.volume(change)
        case .focus(let minutes): return mochi("focus_start", minutes: minutes)
        case .stopFocus: return mochi("focus_stop", minutes: nil)
        case .explore: return mochi("explore", minutes: nil)
        case .comeHome: return mochi("come_home", minutes: nil)
        case .interact(let kind): return mochi(kind.rawValue, minutes: nil)
        case .games: return mochi("games", minutes: nil)
        case .recap: return mochi("recap", minutes: nil)
        case .decorate: return mochi("decorate", minutes: nil)
        case .sessionsStatus: return MacActions.Outcome(text: sessionsSummary())
        case .agentNews: return await environment.agent.answer()
        case .openApp(let name), .switchToApp(let name): return MacActions.openApp(named: name)
        case .openSite(let url): return MacActions.openURL(url.absoluteString)
        }
    }

    /// Mochi's own tricks, for quick commands and the brain's `mochi` tool.
    private func mochi(_ action: String, minutes: Int?) -> MacActions.Outcome {
        switch action {
        case "explore":
            environment.adventure.beginAdventure()
            return MacActions.Outcome(text: "Off to explore your desktop!")
        case "come_home":
            environment.adventure.endAdventure()
            return MacActions.Outcome(text: "Coming home!")
        case "pet":
            world.interact(.pet)
            return MacActions.Outcome(text: "Purrrr…")
        case "play":
            world.interact(.play)
            return MacActions.Outcome(text: "Yay, let's play!")
        case "treat":
            world.interact(.treat)
            return MacActions.Outcome(text: "Nom nom — thank you!")
        case "games":
            environment.games.show()
            return MacActions.Outcome(text: "Let's play a game!", movedFocus: true)
        case "recap":
            environment.recap.show()
            return MacActions.Outcome(text: "Here's your day.", movedFocus: true)
        case "decorate":
            hidePanel(restoreFocus: false)
            environment.roomEditor.beginEditing(openPopover: true)
            return MacActions.Outcome(text: "Let's decorate!", movedFocus: true)
        case "focus_start":
            var durations = FocusTimer.Durations(environment.settingsStore.settings.focus)
            if let minutes { durations.focus = TimeInterval(max(1, min(180, minutes)) * 60) }
            environment.focus.begin(durations: durations)
            return MacActions.Outcome(text: "Focus time — \(Int(durations.focus / 60)) minutes. I'll nap till your break.")
        case "focus_stop":
            environment.focus.stop()
            return MacActions.Outcome(text: "Focus stopped.")
        default:
            return MacActions.Outcome(text: "I don't know that trick.", ok: false)
        }
    }

    // MARK: Claude sessions

    private var liveSessions: [SessionSnapshot] {
        world.sessions.filter { !$0.isSimulated && $0.endedAt == nil && $0.phase != .ended }
            .sorted { $0.lastEventAt > $1.lastEventAt }
    }

    private func stateText(_ session: SessionSnapshot) -> String {
        switch session.phase {
        case .promptSubmitted, .thinking, .runningTool:
            let minutes = session.turnStartedAt.map { max(1, Int(Date().timeIntervalSince($0) / 60)) }
            return "working" + (minutes.map { " (\($0) min)" } ?? "")
        case .waitingForUser: return "waiting for you"
        case .turnFailed: return "stopped with an error"
        case .turnCompleted, .idle: return "idle"
        case .ended: return "ended"
        }
    }

    func sessionsSummary() -> String {
        let sessions = liveSessions.prefix(5)
        guard !sessions.isEmpty else { return "No Claude sessions right now." }
        return sessions.map { "\($0.project?.displayName ?? "A session") is \(stateText($0))" }.joined(separator: " · ") + "."
    }

    private func knownProjects() -> [ProjectRef] {
        var seen = Set<String>()
        return world.sessions.filter { !$0.isSimulated }.compactMap(\.project).filter { seen.insert($0.key).inserted }
    }

    private func host(for project: ProjectRef) -> String? {
        world.sessions.filter { $0.project?.key == project.key && $0.hostApp != nil }
            .max { $0.lastEventAt < $1.lastEventAt }?.hostApp
    }

    private func appName(forBundleID bundleID: String) -> String? {
        if let cached = appNames[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        appNames[bundleID] = name
        return name
    }

    /// When a session Mochi sent a prompt to finishes or needs the user, Mochi says so.
    func worldDidReact(to event: CompanionEvent, session: SessionSnapshot?) {
        guard !delegations.isEmpty, !event.isSimulated, let key = event.project?.key ?? session?.project?.key else { return }
        delegations.removeAll { Date().timeIntervalSince($0.sentAt) > 4 * 3600 }
        guard let index = delegations.firstIndex(where: { $0.project?.key == key && event.timestamp >= $0.sentAt }) else { return }
        let name = delegations[index].project?.displayName ?? "your project"
        let line: String
        switch event.kind {
        case .turnCompleted:
            delegations.remove(at: index)
            line = "Claude finished in \(name)!"
        case .turnFailed:
            delegations.remove(at: index)
            line = "Claude hit a snag in \(name)."
        case .permissionRequested, .attentionNeeded:
            line = "Claude in \(name) needs you."
        default:
            return
        }
        announce(line)
    }

    /// Says a follow-up in Mochi's bubble, after Mochi's own answer has had its moment.
    private func announce(_ line: String) {
        let delay: TimeInterval = phase == .working || phase == .approving ? 3 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.world.say(line, duration: 6)
            if self.settings.spokenReplies { self.speak(line) }
            if self.panelVisible, self.phase == .done {
                self.steps.append(Step(id: UUID().uuidString, symbol: "checkmark.seal", text: line, state: .done))
            }
        }
    }

    // MARK: The brain

    private func brainContext() -> BrainContext {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        let sessions = liveSessions.prefix(8).compactMap { session -> BrainContext.Session? in
            guard let project = session.project else { return nil }
            return BrainContext.Session(project: project.displayName, host: session.hostApp.flatMap(appName(forBundleID:)),
                                        state: stateText(session))
        }
        return BrainContext(time: formatter.string(from: Date()), frontApp: previousApp?.localizedName, sessions: sessions)
    }

    private func askBrain(_ text: String, spoken: Bool) {
        let message = BrainLaunch.message(request: text, context: brainContext(), spoken: spoken)
        if let brain, brain.isRunning {
            brain.send(message)
            armTimeout()
            return
        }
        pendingMessage = message
        startBrain()
    }

    private func startBrain() {
        guard !brainStarting else { return }
        brainStarting = true
        Task {
            let executable = await claudeExecutable()
            brainStarting = false
            guard phase == .working, let message = pendingMessage else { return }
            pendingMessage = nil
            launchBrain(executable: executable, message: message)
        }
    }

    private func launchBrain(executable: String?, message: String) {
        guard let executable else {
            finish("I need Claude Code for that — install it from claude.com/claude-code, then ask again.", ok: false)
            return
        }
        let installed = environment.paths.installedHelper.path
        guard let helper = environment.integration.bundledHelper?.path
                ?? (FileManager.default.isExecutableFile(atPath: installed) ? installed : nil) else {
            finish("My helper tool is missing. Reinstalling MacTamagotchi fixes it.", ok: false)
            return
        }
        guard paws.start() else {
            finish("I couldn't open my private tool socket.", ok: false)
            return
        }
        let token = Self.randomToken()
        paws.expect(token: token)
        let directory = environment.paths.assistantDirectory
        BridgePaths.ensurePrivateDirectory(directory)
        let configURL = directory.appendingPathComponent("mcp.json")
        let config = BrainLaunch.mcpConfig(helper: helper, socket: environment.paths.pawsSocketFile.path, token: token)
        guard FileManager.default.createFile(atPath: configURL.path, contents: Data(config.jsonText.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            finish("I couldn't write my tool settings.", ok: false)
            return
        }
        chmod(configURL.path, 0o600)
        let launch = BrainLaunch(executable: executable, model: settings.model.alias, mcpConfigPath: configURL.path,
                                 workingDirectory: directory.path, petName: petName)
        let session = BrainSession(launch: launch)
        session.onEvent = { [weak self] event in self?.handle(event) }
        session.onExit = { [weak self, weak session] status, tail in self?.brainExited(session, status: status, tail: tail) }
        do {
            try session.start()
        } catch {
            finish("Claude Code didn't start (\(error.localizedDescription)).", ok: false)
            return
        }
        brain = session
        session.send(message)
        armTimeout()
    }

    private func claudeExecutable() async -> String? {
        if let installed = environment.integration.installation?.executable.path { return installed }
        return await Task.detached(priority: .userInitiated) { ClaudeCodeLocator.locate()?.executable.path }.value
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func armTimeout() {
        timeout?.invalidate()
        let timer = Timer(timeInterval: Self.requestTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .working else { return }
                self.stopCurrent()
                self.finish("That took too long, so I stopped.", ok: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timeout = timer
    }

    private func scheduleIdleShutdown() {
        idleShutdown?.invalidate()
        guard brain != nil else { return }
        let timer = Timer(timeInterval: Self.idleShutdownDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase != .working, self.phase != .approving else { return }
                self.brain?.terminate()
                self.brain = nil
                self.paws.expect(token: nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleShutdown = timer
    }

    private func handle(_ event: BrainEvent) {
        guard phase == .working || phase == .approving else { return }
        switch event {
        case .started, .text:
            break
        case .toolUse(let id, let name, let input):
            guard let step = BrainStep.describe(tool: name, input: input) else { return }
            steps.append(Step(id: id, symbol: step.symbol, text: step.text, state: .running))
        case .toolResult(let id, let isError, let text):
            guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
            steps[index].state = isError ? .failed : .done
            let asking = "Asking to send to "
            if steps[index].text.hasPrefix(asking) {
                let target = steps[index].text.dropFirst(asking.count)
                let approved = approvedMessages.removeValue(forKey: id)
                if !isError, Self.delivered(text), let approved {
                    steps[index].text = "Sent to \(target)"
                    let finishedAlready = approved.project.map { project in
                        world.sessions.contains { $0.project?.key == project.key && ($0.lastTurnCompletedAt ?? .distantPast) >= approved.at }
                    } ?? false
                    if finishedAlready, let project = approved.project {
                        announce("Claude finished in \(project.displayName)!")
                    } else {
                        delegations.append(Delegation(project: approved.project, sentAt: approved.at))
                    }
                } else {
                    steps[index].text = "Not sent to \(target)"
                    steps[index].state = .failed
                }
            }
        case .finished(let result, let isError, _):
            let text = Self.cleanReply(result) ?? (isError ? "Something went wrong." : "Done!")
            finish(text, ok: !isError, movedFocus: movedFocus)
        }
    }

    private func brainExited(_ session: BrainSession?, status: Int32, tail: String) {
        guard let session, session === brain else { return }
        brain = nil
        paws.expect(token: nil)
        guard phase == .working || phase == .approving else { return }
        resolveApproval(false)
        let lowered = tail.lowercased()
        if lowered.contains("login") || lowered.contains("log in") || lowered.contains("authenticat") {
            finish("Claude Code needs you to sign in — run `claude` once in Terminal, then ask again.", ok: false)
        } else {
            finish("My helper Claude stopped unexpectedly (code \(status)).", ok: false)
        }
    }

    /// Whether Claude Code reported a SendMessage as delivered (`{"success":true,…}`).
    static func delivered(_ result: String) -> Bool {
        if let success = AnyJSON.parse(Data(result.utf8))?["success"]?.boolValue { return success }
        return result.contains("\"success\":true")
    }

    /// The brain's last sentence, without markdown.
    static func cleanReply(_ text: String?) -> String? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return text.count > 400 ? String(text.prefix(399)) + "…" : text
    }

    // MARK: Tools ("paws")

    static let tools: [MCPToolSpec] = [
        MCPToolSpec(name: BrainLaunch.approvalTool,
                    description: "Internal: Mochi's approval card for messages to Claude sessions. Never call this yourself.",
                    properties: ["tool_name": ("string", "Tool waiting for approval"), "input": ("object", "Its input")],
                    required: ["tool_name", "input"]),
        MCPToolSpec(name: "open_url", description: "Open an https link in the user's default browser.",
                    properties: ["url": ("string", "The https URL")], required: ["url"]),
        MCPToolSpec(name: "open_app", description: "Open an app by name, or switch to it if it is running.",
                    properties: ["name": ("string", "App name, e.g. Slack or Visual Studio Code")], required: ["name"]),
        MCPToolSpec(name: "list_apps", description: "Names of the apps that are running now."),
        MCPToolSpec(name: "focus_window",
                    description: "Bring a window to the front. Give the app and/or words from the window's title; the title is matched on the Mac.",
                    properties: ["app": ("string", "App name (optional)"), "title": ("string", "Words from the window title (optional)")]),
        MCPToolSpec(name: "show_project",
                    description: "Bring forward the window a Claude session works in (its editor or terminal), by project or session name.",
                    properties: ["project": ("string", "Project folder or session name, e.g. mac-Tamagotchi")], required: ["project"]),
        MCPToolSpec(name: "media", description: "Press a music key: play/pause, next or previous (whatever is playing).",
                    properties: ["action": ("string", "play_pause, next or previous")], required: ["action"],
                    enumValues: ["action": ["play_pause", "next", "previous"]]),
        MCPToolSpec(name: "set_volume", description: "Change the Mac's volume: a level 0–100, or up/down/mute/unmute.",
                    properties: ["level": ("number", "0–100 (optional)"), "change": ("string", "up, down, mute or unmute (optional)")],
                    enumValues: ["change": ["up", "down", "mute", "unmute"]]),
        MCPToolSpec(name: "run_shortcut", description: "Run one of the user's Shortcuts by its exact name.",
                    properties: ["name": ("string", "Shortcut name")], required: ["name"]),
        MCPToolSpec(name: "list_shortcuts", description: "Names of the user's Shortcuts."),
        MCPToolSpec(name: "mochi", description: "Mochi's own tricks.",
                    properties: ["action": ("string", "What Mochi should do"), "minutes": ("number", "Focus length (focus_start only)")],
                    required: ["action"],
                    enumValues: ["action": ["explore", "come_home", "pet", "play", "treat", "games", "recap", "decorate", "focus_start", "focus_stop"]]),
        MCPToolSpec(name: "claude_sessions", description: "The user's Claude sessions Mochi knows about and what each is doing."),
    ]

    private func performTool(name: String, arguments: AnyJSON) async -> (text: String, isError: Bool) {
        if name == BrainLaunch.approvalTool { return (await approvalVerdict(arguments), false) }
        let outcome: MacActions.Outcome
        switch name {
        case "open_url":
            outcome = MacActions.openURL(arguments["url"]?.stringValue ?? "")
        case "open_app":
            outcome = MacActions.openApp(named: arguments["name"]?.stringValue ?? "")
        case "list_apps":
            outcome = MacActions.Outcome(text: "Running: " + MacActions.runningApps().compactMap(\.localizedName).sorted().joined(separator: ", "))
        case "focus_window":
            outcome = MacActions.focusWindow(app: arguments["app"]?.stringValue, title: arguments["title"]?.stringValue)
        case "show_project":
            let wanted = arguments["project"]?.stringValue ?? ""
            let projects = knownProjects()
            if let project = AgentNames.project(forAgent: wanted, among: projects)
                ?? projects.first(where: { $0.displayName.caseInsensitiveCompare(wanted) == .orderedSame }) {
                outcome = MacActions.showProject(project, host: host(for: project))
            } else {
                outcome = MacActions.focusWindow(app: nil, title: wanted)
            }
        case "media":
            let key: MediaKey
            switch arguments["action"]?.stringValue {
            case "next": key = .next
            case "previous": key = .previous
            default: key = .playPause
            }
            outcome = MacActions.media(key)
        case "set_volume":
            if let level = arguments["level"]?.numberValue {
                outcome = MacActions.volume(.set(Int(level.rounded())))
            } else {
                let change: VolumeChange
                switch arguments["change"]?.stringValue {
                case "down": change = .down
                case "mute": change = .mute
                case "unmute": change = .unmute
                default: change = .up
                }
                outcome = MacActions.volume(change)
            }
        case "run_shortcut":
            outcome = await MacActions.runShortcut(arguments["name"]?.stringValue ?? "")
        case "list_shortcuts":
            let names = await MacActions.shortcutNames()
            outcome = MacActions.Outcome(text: names.isEmpty ? "No shortcuts found." : names.prefix(60).joined(separator: ", "))
        case "mochi":
            outcome = mochi(arguments["action"]?.stringValue ?? "", minutes: arguments["minutes"]?.numberValue.map { Int($0) })
        case "claude_sessions":
            outcome = MacActions.Outcome(text: sessionsSummary())
        default:
            outcome = MacActions.Outcome(text: "Unknown tool.", ok: false)
        }
        if outcome.movedFocus { movedFocus = true }
        return (outcome.text, !outcome.ok)
    }

    // MARK: Approvals

    /// The answer Claude Code's permission prompt tool expects.
    private func approvalVerdict(_ arguments: AnyJSON) async -> String {
        func deny(_ message: String) -> String {
            AnyJSON.object(["behavior": "deny", "message": .string(message)]).jsonText
        }
        guard arguments["tool_name"]?.stringValue == "SendMessage" else {
            return deny("Mochi only approves messages to the user's Claude sessions.")
        }
        let input = arguments["input"] ?? .object([:])
        let target = AgentNames.display(input["to"]?.stringValue ?? input["recipient"]?.stringValue ?? "")
        let message = input["message"]?.stringValue ?? input["content"]?.stringValue ?? ""
        guard !target.isEmpty, !message.isEmpty, phase == .working || phase == .approving else {
            return deny("Nothing to send.")
        }
        let project = AgentNames.project(forAgent: target, among: knownProjects())
        let allowed = settings.confirmBeforeSending && !isDirectReply(to: project, message: message)
            ? await askApproval(Approval(target: target, project: project, message: message))
            : true
        guard allowed else { return deny("The user chose not to send it.") }
        if let toolUseID = arguments["tool_use_id"]?.stringValue { approvedMessages[toolUseID] = (project, Date()) }
        if let project {
            let outcome = MacActions.showProject(project, host: host(for: project))
            if outcome.movedFocus { movedFocus = true }
        }
        return AnyJSON.object(["behavior": "allow", "updatedInput": input]).jsonText
    }

    /// A reply the user wrote for this very session needs no second OK, as long as the brain picked
    /// that project, the session replied to is the project's only live one, and the words are the user's.
    private func isDirectReply(to project: ProjectRef?, message: String) -> Bool {
        guard let target, let request, let project, project.displayName == target.project else { return false }
        let sessions = liveSessions.filter { $0.project?.key == project.key }
        guard sessions.count == 1, target.sessionID == nil || sessions[0].id == target.sessionID else { return false }
        return BrainLaunch.keepsWords(message, of: request)
    }

    private func askApproval(_ request: Approval) async -> Bool {
        resolveApproval(false)
        approval = request
        setPhase(.approving)
        timeout?.invalidate()
        if !panelVisible, !headless { showPanel() }
        if case .phone(let commandID) = origin {
            environment.phone.mirrorApproval(id: request.id.uuidString, commandID: commandID, target: request.target,
                                             project: request.project?.displayName, message: request.message)
        }
        let expiry = Timer(timeInterval: 120, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.resolveApproval(false) }
        }
        RunLoop.main.add(expiry, forMode: .common)
        let allowed = await withCheckedContinuation { continuation in approvalContinuation = continuation }
        expiry.invalidate()
        approval = nil
        environment.phone.clearApproval()
        if phase == .approving {
            setPhase(.working)
            armTimeout()
        }
        return allowed
    }

    func approve() { resolveApproval(true) }
    func decline() { resolveApproval(false) }

    /// The approval card's answer, given on the iPhone.
    func answerFromPhone(approvalID: String, allow: Bool) {
        guard approval?.id.uuidString == approvalID else { return }
        resolveApproval(allow)
    }

    private func resolveApproval(_ allowed: Bool) {
        guard let continuation = approvalContinuation else { return }
        approvalContinuation = nil
        continuation.resume(returning: allowed)
    }

    // MARK: Voice

    func startListening() {
        guard settings.enabled, phase != .approving else { return }
        if !panelVisible { showPanel() }
        if phase == .working { stopCurrent() }
        transcript = ""
        setPhase(.listening)
        voice.start { [weak self] text in
            self?.transcript = text
        } failed: { [weak self] message in
            guard let self, self.phase == .listening else { return }
            self.request = nil
            self.finish(message, ok: false)
        }
    }

    func stopListening(submit: Bool) {
        guard phase == .listening else { return }
        Task {
            let heard = await voice.stop()
            guard self.phase == .listening else { return }
            let text = (heard ?? self.transcript).trimmingCharacters(in: .whitespacesAndNewlines)
            self.transcript = ""
            if submit, !text.isEmpty {
                self.run(text, spoken: true)
            } else {
                self.setPhase(.idle)
                if submit { self.reply = "I didn't catch that." }
            }
        }
    }

    // MARK: Development

    private func registerDebugHooks() {
        environment.debug.register("assistant") { [weak self] argument in
            guard let self else { return }
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            switch parts.first ?? "" {
            case "ask": self.run(value, headless: true)
            case "approve": self.approve()
            case "decline": self.decline()
            case "cancel": self.cancelRequest()
            case "show": self.showPanel()
            case "hide": self.hidePanel(restoreFocus: false)
            case "snapshot": AskMochiSnapshots.render(controller: self, environment: self.environment)
            case "capture": self.captureRealPanel()
            default: break
            }
        }
        environment.debug.registerState("assistant") { [weak self] in
            guard let self else { return NSNull() }
            return [
                "phase": "\(self.phase)",
                "request": self.request ?? "",
                "reply": self.reply ?? "",
                "steps": self.steps.map { "\($0.state): \($0.text)" },
                "approval": self.approval.map { ["target": $0.target, "project": $0.project?.displayName ?? "", "message": $0.message] as Any } ?? NSNull(),
                "brainRunning": self.brain?.isRunning ?? false,
                "pawsListening": self.paws.isListening,
                "delegations": self.delegations.count,
                "panelVisible": self.panelVisible,
                "shortcutProblem": self.shortcutProblem ?? "",
            ]
        }
    }

    // MARK: Snapshot support

    /// Development: draws the real panel off-screen (no focus change) in each preview state and
    /// saves `debug-ask-window-<state>.png`.
    private func captureRealPanel() {
        let states = AskMochiSnapshots.states()
        func step(_ index: Int) {
            guard index < states.count else {
                panel.orderOut(nil)
                previewState(phase: .idle, request: nil, steps: [], approval: nil, reply: nil)
                return
            }
            let state = states[index]
            previewState(phase: state.phase, request: state.request, steps: state.steps, approval: state.approval,
                         reply: state.reply, transcript: state.transcript)
            panel.setFrameOrigin(NSPoint(x: -6000, y: -6000))
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, let view = self.panel.contentView else { return }
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: self.environment.paths.home.appendingPathComponent("debug-ask-window-\(state.name).png"))
                }
                step(index + 1)
            }
        }
        step(0)
    }

    /// Puts the view model in a given state for rendering previews (development only).
    func previewState(phase: Phase, request: String?, steps: [Step], approval: Approval?, reply: String?, transcript: String = "") {
        self.phase = phase
        self.request = request
        self.steps = steps
        self.approval = approval
        self.reply = reply
        self.transcript = transcript
    }
}
