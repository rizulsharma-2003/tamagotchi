import AppKit
import Foundation
import Observation
import Security
import TamagotchiCore
import TamagotchiWire

/// Mochi's personal agent. Every few minutes a short background `claude -p` (Haiku, your Claude
/// subscription) reads what's new in Gmail, Google Calendar and Notion through the connectors in your
/// Claude account — read-only tools, nothing else — and Mochi tells you what matters: a speech bubble,
/// a menu-bar badge and, if you like, your iPhone. A morning briefing sums up the day.
@MainActor
@Observable
final class AgentController {
    private(set) var connections: [AgentSource: AgentConnection] = [:]
    private(set) var checkingConnections = false
    private(set) var running = false
    private(set) var lastRunAt: Date?
    private(set) var lastResult: String?
    private(set) var lastError: String?
    private(set) var notes: [AgentNote] = []
    /// Ids you marked done, here or in Mochi Pocket.
    private(set) var doneIDs: Set<String> = []

    @ObservationIgnored private unowned let environment: AppEnvironment
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var memory = AgentMemory()
    @ObservationIgnored private var lastConnectionCheck = Date.distantPast
    /// After Connect…, look again now and then until the user is back with everything connected.
    @ObservationIgnored private var watchConnectionsUntil: Date?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var markingRead = false
    @ObservationIgnored private var lastMarkReadAttempt = Date.distantPast
    /// Meetings Mochi has already nudged you about ("event id@start").
    @ObservationIgnored private var nudgedMeetings = Set<String>()

    enum Reason { case scheduled, morning, asked, settings }

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    private var settings: AgentSettings { environment.settingsStore.settings.agent }

    /// Watched and connected.
    var activeSources: [AgentSource] { settings.watched.filter { connections[$0] == .connected } }

    func start() {
        memory = AgentMemory.load(from: environment.paths.agentFile)
        memory.prune(now: Date())
        notes = memory.notes
        doneIDs = Set(memory.done.keys)
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        registerDebugHooks()
        started = true
        phoneDoneChanged()
        // Mochi Pocket may have been reinstalled: share the cloud's "check now" link again.
        if cloudTriggerSaved, let token = CloudTokenStore.load() {
            environment.phone.publishCloudTrigger(url: settings.cloudFireURL, token: token)
        }
    }

    private func tick() {
        // Opening the panel counts as having seen the news.
        if environment.ui.popoverVisible, environment.world.agentBadge != nil { environment.world.agentBadge = nil }
        // Meetings that have started leave the Pending card.
        if memory.prunePending(now: Date()) { save() }
        publishPending()
        if !memory.threadsToMarkRead.isEmpty, Date().timeIntervalSince(lastMarkReadAttempt) > 600 { markReadIfNeeded() }
        nudgeBeforeMeetings()
        if let until = watchConnectionsUntil {
            if Date() > until {
                watchConnectionsUntil = nil
            } else if !checkingConnections, Date().timeIntervalSince(lastConnectionCheck) > 20 {
                Task { await refreshConnections(forgetNotes: true) }
            }
        }
        guard settings.enabled, !running else { return }
        let now = Date()
        if AgentSchedule.briefingDue(settings, lastBriefingDay: memory.lastBriefingDay, now: now) {
            Task { await run(.briefing, reason: .morning) }
        } else if AgentSchedule.checkDue(settings, lastCheck: lastCheck, now: now) {
            Task { await run(.check(since: AgentSchedule.since(lastCheck: lastCheck, now: now)), reason: .scheduled) }
        }
    }

    private var lastCheck: Date? { memory.lastCheckAt.map(Date.init(timeIntervalSince1970:)) }

    // MARK: Connections

    /// Opens the Claude account's connectors in the browser; Mochi keeps looking until they're connected.
    func connect() {
        AgentConnections.forgetSignInNotes(cacheFile: Self.signInNotesFile)
        NSWorkspace.shared.open(AgentConnections.connectURL)
        watchConnectionsUntil = Date().addingTimeInterval(5 * 60)
    }

    func refreshConnections(forgetNotes: Bool = false) async {
        guard !checkingConnections else { return }
        guard let executable = environment.integration.installation?.executable.path else {
            lastError = "Claude Code isn't installed on this Mac, so \(environment.settingsStore.settings.petName) can't reach your connectors."
            return
        }
        let directory = environment.paths.assistantDirectory
        guard BridgePaths.ensurePrivateDirectory(directory) else { return }
        checkingConnections = true
        defer { checkingConnections = false }
        if forgetNotes { AgentConnections.forgetSignInNotes(cacheFile: Self.signInNotesFile) }
        lastConnectionCheck = Date()
        let output = await AgentRunner.run(arguments: AgentConnections.probeArguments, input: AgentConnections.probePrompt,
                                           executable: executable, directory: directory,
                                           environment: AgentCommand.environment(from: BrainSession.environment()), timeout: 90)
        guard let output, let states = AgentConnections.parse(probeOutput: output) else {
            lastError = output.flatMap(AgentDigest.failure) ?? "Couldn't check the connections just now."
            return
        }
        connections = states
        if watchConnectionsUntil != nil, settings.watched.allSatisfy({ states[$0] == .connected }) { watchConnectionsUntil = nil }
    }

    /// Claude Code's note of connectors that needed signing in (see `AgentConnections.forgetSignInNotes`).
    static var signInNotesFile: URL {
        let directory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        return directory.appendingPathComponent("mcp-needs-auth-cache.json")
    }

    // MARK: Checking

    func checkNow() {
        Task { await run(.check(since: AgentSchedule.since(lastCheck: lastCheck, now: Date())), reason: .settings) }
    }

    func briefNow() {
        Task { await run(.briefing, reason: .settings) }
    }

    /// Ask Mochi's "what's pending?": the day at a glance, said out loud.
    func answer() async -> MacActions.Outcome {
        let name = environment.settingsStore.settings.petName
        guard settings.enabled else {
            return MacActions.Outcome(text: "Turn on \(name)'s agent in Settings › Agent first.", ok: false)
        }
        guard !running else { return MacActions.Outcome(text: "I'm checking right now — give me a moment.") }
        guard let digest = await run(.briefing, reason: .asked) else {
            return MacActions.Outcome(text: lastError ?? "I couldn't check just now.", ok: false)
        }
        let everything = AgentNews(emails: digest.emails, events: digest.events, tasks: digest.tasks, vips: settings.vips)
        let extra = everything.parts().prefix(2).filter { !digest.headline.contains($0) }
        return MacActions.Outcome(text: ([digest.headline] + extra).joined(separator: ". "))
    }

    @discardableResult
    private func run(_ mode: AgentMode, reason: Reason) async -> AgentDigest? {
        guard !running else { return nil }
        running = true
        defer { running = false }
        if connections.isEmpty || Date().timeIntervalSince(lastConnectionCheck) > 6 * 3600 { await refreshConnections() }
        let sources = activeSources
        guard !sources.isEmpty else {
            lastError = "Connect Gmail, Google Calendar or Notion first."
            if case .check = mode { memory.lastCheckAt = Date().timeIntervalSince1970 }
            return nil
        }
        guard let executable = environment.integration.installation?.executable.path else {
            lastError = "Claude Code isn't installed on this Mac."
            return nil
        }
        let directory = environment.paths.assistantDirectory
        guard BridgePaths.ensurePrivateDirectory(directory) else { return nil }
        let started = Date()
        let output = await AgentRunner.run(arguments: AgentCommand.arguments(sources: sources),
                                           input: AgentCommand.prompt(mode: mode, sources: sources, now: started),
                                           executable: executable, directory: directory,
                                           environment: AgentCommand.environment(from: BrainSession.environment()), timeout: 180)
        lastRunAt = Date()
        if case .check = mode { memory.lastCheckAt = started.timeIntervalSince1970 }
        guard let output, let digest = AgentDigest.parse(output: output) else {
            lastError = output.flatMap(AgentDigest.failure) ?? "The check didn't finish in time."
            save()
            return nil
        }
        lastError = nil
        switch mode {
        case .check:
            let news = memory.news(from: digest, now: started, vips: settings.vips)
            memory.updatePending(with: news.notes(at: started), replacing: false, headline: nil, now: started)
            lastResult = news.isEmpty ? "Nothing new" : news.line()
            tell(news)
        case .briefing:
            memory.markSeen(digest, now: started)
            let done = memory.done
            let everything = AgentNews(emails: digest.emails.filter { done["mail:" + $0.id] == nil },
                                       events: digest.events.filter { done["event:" + $0.id] == nil },
                                       tasks: digest.tasks.filter { done["task:" + $0.id] == nil }, vips: settings.vips)
            lastResult = digest.headline
            memory.remember(everything.notes(at: started))
            memory.updatePending(with: everything.notes(at: started), replacing: true, headline: digest.headline, now: started)
            if reason == .morning {
                memory.lastBriefingDay = AgentSchedule.dayKey(started)
                tell(everything, headline: digest.headline, phoneTitle: "Your day")
            } else if reason == .settings {
                tell(everything, headline: digest.headline, phoneTitle: "Your day", phone: false)
            }
        }
        save()
        publishPending(force: true)
        return digest
    }

    /// About ten minutes before a meeting on the card, Mochi says so (your iPhone gets Mochi Cloud's heads-up).
    private func nudgeBeforeMeetings() {
        guard settings.enabled, settings.tellInBubble else { return }
        let now = Date().timeIntervalSince1970
        for note in memory.pending where note.source == .calendar && memory.done[note.id] == nil {
            guard let due = note.due, (300...660).contains(due - now) else { continue }
            let key = note.id + "@" + String(Int(due))
            guard nudgedMeetings.insert(key).inserted else { continue }
            let minutes = max(1, Int(((due - now) / 60).rounded()))
            environment.world.say("\(note.title) in \(minutes) minutes" + (note.link != nil ? " — the link's on the card" : ""),
                                  speaker: .pet, duration: 10)
            if settings.tellWithBadge { environment.world.agentBadge = .attention }
            break
        }
    }

    // MARK: Done

    func isDone(_ id: String) -> Bool { doneIDs.contains(id) }

    /// Done here (Settings › Agent › Recent): off the card on both devices, and read in Gmail if you like.
    func markDone(_ note: AgentNote) {
        guard memory.markDone([note.id: Date().timeIntervalSince1970.rounded()]) else { return }
        save()
        publishPending(force: true)
        environment.phone.publishMacDone(AgentDoneList(ids: memory.done).trimmed())
        markReadIfNeeded()
    }

    /// Mochi Pocket's done list changed (through Mochi Link).
    func phoneDoneChanged() {
        guard started, let list = environment.phone.phoneDone else { return }
        guard memory.markDone(list.trimmed().ids) else { return }
        save()
        publishPending(force: true)
        environment.phone.publishMacDone(AgentDoneList(ids: memory.done).trimmed())
        if memory.pending.isEmpty { environment.world.agentBadge = nil }
        markReadIfNeeded()
    }

    /// Removes the UNREAD label from mail you marked done: the one change Mochi makes in Gmail, and only
    /// with "Mark email read when I mark it done" on.
    private func markReadIfNeeded() {
        guard settings.enabled, settings.markReadWhenDone, !markingRead, connections[.gmail] == .connected,
              let executable = environment.integration.installation?.executable.path else { return }
        let threads = Array(memory.threadsToMarkRead.prefix(20))
        guard !threads.isEmpty else { return }
        let directory = environment.paths.assistantDirectory
        guard BridgePaths.ensurePrivateDirectory(directory) else { return }
        markingRead = true
        lastMarkReadAttempt = Date()
        Task {
            defer { markingRead = false }
            let output = await AgentRunner.run(arguments: AgentCommand.markReadArguments,
                                               input: AgentCommand.markReadPrompt(threadIDs: threads),
                                               executable: executable, directory: directory,
                                               environment: AgentCommand.environment(from: BrainSession.environment()), timeout: 120)
            guard let output, AgentCommand.markReadSucceeded(output: output) else { return }
            let now = Date().timeIntervalSince1970.rounded()
            for thread in threads { memory.markedRead[thread] = now }
            save()
        }
    }

    // MARK: Mochi Pocket's Pending card

    @ObservationIgnored private var publishedPending: String?
    @ObservationIgnored private var pendingPublishedAt = Date.distantPast

    /// What's waiting for you, shared only while the agent is on with "On my iPhone".
    private func pendingCard(stamped: Bool) -> AgentPending {
        let shared = settings.enabled && settings.tellPhone
        let looked = lastRunAt?.timeIntervalSince1970 ?? memory.lastCheckAt
        var card = AgentPending(enabled: shared, headline: shared ? memory.pendingHeadline : nil, items: shared ? memory.pending : [],
                                lookedAt: shared ? looked?.rounded() : nil)
        if stamped { card.updatedAt = Date().timeIntervalSince1970.rounded(.up) }
        return card
    }

    /// At most every half minute unless something was just found: the card only changes when Mochi looks.
    private func publishPending(force: Bool = false) {
        let json = pendingCard(stamped: false).json
        guard json != publishedPending, force || Date().timeIntervalSince(pendingPublishedAt) >= 30 else { return }
        publishedPending = json
        pendingPublishedAt = Date()
        environment.phone.publishAgentPending(pendingCard(stamped: true).json)
    }

    private func tell(_ news: AgentNews, headline: String? = nil, phoneTitle: String? = nil, phone: Bool = true) {
        guard !news.isEmpty || headline != nil else { return }
        memory.remember(news.notes(at: Date()))
        let line = headline ?? news.line()
        if settings.tellInBubble, !line.isEmpty { environment.world.say(line, speaker: .pet, duration: 8) }
        if settings.tellWithBadge, let level = news.attention {
            environment.world.agentBadge = max(environment.world.agentBadge ?? level, level)
        }
        guard phone, settings.tellPhone, headline != nil || news.worthPhone(skippingLow: settings.phoneSkipsLowPriority) else { return }
        var notification = news.notification()
        if let phoneTitle { notification.title = phoneTitle }
        if let headline { notification.body = notification.body.isEmpty ? headline : headline + "\n" + notification.body }
        environment.phone.sendAgentNews(title: notification.title, body: notification.body, pending: pendingCard(stamped: true),
                                        quietIfKnown: headline == nil)
    }

    private func save() {
        memory.prune(now: Date())
        memory.save(to: environment.paths.agentFile)
        notes = memory.notes
        doneIDs = Set(memory.done.keys)
    }

    // MARK: Mochi Cloud

    /// Makes Mochi Cloud its own `cloud` device in this Mac's Mochi Link room and copies its settings (relay, room, its
    /// credential and the room key). It needs no push key and no phone address: the relay pushes for it.
    func copyCloudLinkSettings() async -> (ok: Bool, message: String) {
        guard let host = environment.link.credentials else {
            return (false, "Pair a phone with Mochi Link first (Settings › Phones › Mochi Link).")
        }
        do {
            let code = try await LinkPairing.invite(host, hostName: LinkController.macName, role: "cloud")
            let cloud = try await LinkPairing.join(code, role: "cloud", platform: "cloud", name: "Mochi Cloud")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(AgentCloud.linkEnvironmentBlock(cloud), forType: .string)
            return (true, "Copied. On claude.ai/code, open your Mochi Cloud environment › Environment variables and paste it in. "
                + "It holds a key to your link, so don't share it.")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    var cloudTriggerSaved: Bool { !settings.cloudFireURL.isEmpty && CloudTokenStore.load() != nil }

    /// Stores Mochi Cloud's API trigger (the token in the Keychain) and shares it with Mochi Pocket.
    func saveCloudTrigger(url: String, token: String) -> String? {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentCloud.isFireURL(url) else { return "Paste the Fire URL from the task's API trigger (it ends in /fire)." }
        guard token.count > 20, !token.contains(" ") else { return "Paste the token shown when you generated it." }
        guard CloudTokenStore.save(token) else { return "The token couldn't be saved in the Keychain." }
        environment.settingsStore.settings.agent.cloudFireURL = url
        environment.phone.publishCloudTrigger(url: url, token: token)
        return nil
    }

    /// Puts the Mochi Watcher (Google Apps Script) on the clipboard with this Mac's cloud trigger filled in.
    func copyWatcherScript() -> (ok: Bool, message: String) {
        guard let token = CloudTokenStore.load(),
              let script = AgentCloud.watcherScript(fireURL: settings.cloudFireURL, token: token, vips: settings.vips) else {
            return (false, "Save Mochi Cloud's Fire URL and token first.")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(script, forType: .string)
        return (true, "Copied. At script.google.com: New project, paste over everything, pick “setup” next to Run, press Run and allow access.")
    }

    func removeCloudTrigger() {
        CloudTokenStore.delete()
        environment.settingsStore.settings.agent.cloudFireURL = ""
        environment.phone.publishCloudTrigger(url: nil, token: nil)
    }

    /// Forgets what Mochi has told you (so the next check reports everything again).
    func forgetNews() {
        memory = AgentMemory()
        save()
        environment.world.agentBadge = nil
        publishPending(force: true)
    }

    // MARK: Development

    private func registerDebugHooks() {
        environment.debug.register("agent") { [weak self] argument in
            guard let self else { return }
            switch argument {
            case "check": self.checkNow()
            case "brief": self.briefNow()
            case "connections": Task { await self.refreshConnections(forgetNotes: true) }
            case "forget": self.forgetNews()
            case "markread": self.markReadIfNeeded()
            default: break
            }
        }
        environment.debug.registerState("agent") { [weak self] in
            guard let self else { return NSNull() }
            return [
                "enabled": self.settings.enabled, "running": self.running,
                "connections": Dictionary(uniqueKeysWithValues: self.connections.map { ($0.key.rawValue, $0.value.rawValue) }),
                "lastResult": self.lastResult ?? "", "lastError": self.lastError ?? "", "notes": self.notes.count,
                "badge": self.environment.world.agentBadge.map { "\($0)" } ?? "",
                "done": self.memory.done.count, "toMarkRead": self.memory.threadsToMarkRead.count, "vips": self.settings.vips.count,
            ]
        }
    }
}

/// Mochi Cloud's API-trigger token in the login Keychain (it can only start that one scheduled task).
enum CloudTokenStore {
    private static let service = "dev.mactamagotchi.mochi-cloud-trigger"

    static func save(_ token: String) -> Bool {
        delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "fire",
            kSecAttrLabel as String: "MacTamagotchi Mochi Cloud trigger", kSecValueData as String: Data(token.utf8),
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "fire",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "fire"]
        SecItemDelete(query as CFDictionary)
    }
}
