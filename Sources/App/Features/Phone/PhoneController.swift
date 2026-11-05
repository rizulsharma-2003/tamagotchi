import AppKit
import CryptoKit
import Foundation
import Observation
import os
import TamagotchiCore
import TamagotchiWire

/// Mochi on the user's phones: a Live Activity in the Mochi Pocket app, summaries and agent news as notifications, and
/// the room, commands and approvals, all through Mochi Link (docs/MOCHI_LINK_PLAN.md). The relay holds the push key and
/// the phones' push addresses; what it pushes is sealed with the room key, so only the phones can read it. Unpaired,
/// nothing leaves this Mac. Only the phase, a short title and, if allowed, the project name and a tool count go into
/// the Live Activity.
@MainActor
@Observable
final class PhoneController {
    /// The iPhone's push-to-start address, as it shares it through the link: set once a Live Activity can be started.
    private(set) var pushToStartToken: String?
    private(set) var updateTokens: [String: String] = [:]
    private(set) var tokensSavedAt: Date?
    private(set) var lastResult: String?
    private(set) var lastError: String?
    private(set) var activityRunning = false
    private(set) var shown: LiveActivityState?

    @ObservationIgnored private unowned let environment: AppEnvironment
    @ObservationIgnored private var timer: Timer?
    /// Where the Mac and the phones meet: the Mochi Link relay once paired, else nowhere (this Mac keeps its own writes).
    private var link: LinkStore { MochiLink.store }
    @ObservationIgnored private var desired: LiveActivityState?
    @ObservationIgnored private var lastSentAt = Date.distantPast
    @ObservationIgnored private var lastTimestamp = 0.0
    @ObservationIgnored private var testUntil: Date?
    /// When you ended it from Settings; it stays away until Claude starts something newer.
    @ObservationIgnored private var endedByHandAt: Date?
    @ObservationIgnored private var handledCommands = Set(UserDefaults.standard.stringArray(forKey: "phoneHandledCommands") ?? [])
    @ObservationIgnored private var pendingApprovalID: String?
    private(set) var lastCommand: String?

    private static let quietUpdateInterval: TimeInterval = 8
    private static let linkLog = Logger(subsystem: "com.mochi.link", category: "mac")
    /// While Claude works, a quiet update this often moves Mochi and Patch to their next pose.
    private static let motionInterval: TimeInterval = 6
    @ObservationIgnored private var frameCounter = 0
    /// When this Mac last started the Live Activity (Unix time).
    @ObservationIgnored private var activityStartedAt = 0.0

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    private var settings: PhoneSettings { environment.settingsStore.settings.phone }

    /// Paired with Mochi Link: the phones can be reached.
    var paired: Bool { MochiLink.relay != nil }

    func start() {
        NotificationCenter.default.addObserver(forName: .linkStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readTokens() }
        }
        readTokens()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        registerDebugHooks()
    }

    func readTokens() {
        pushToStartToken = link.string(.pushToStart)
        let tokens = link.value(.updateTokens) as? [String: String] ?? [:]
        let gained = Set(tokens.values).subtracting(updateTokens.values)
        let hadTokens = !updateTokens.isEmpty
        updateTokens = tokens
        tokensSavedAt = link.double(.tokensSavedAt).map(Date.init(timeIntervalSince1970:))
        deviceToken = link.string(.deviceToken)
        // The iPhone lists its running activities; follow it rather than guessing. Only a list the phone saved after
        // this activity started counts: a list that merely looks empty for a moment (a relay reconnect, a sync still
        // on its way) mustn't read as "you swiped it away".
        let reportedSince = (tokensSavedAt?.timeIntervalSince1970 ?? 0) > activityStartedAt
        if activityRunning, hadTokens, tokens.isEmpty, reportedSince {
            // Gone from the phone (swiped away, or the app was reinstalled): back for Claude's next turn.
            Self.linkLog.notice("live activity: the iPhone reports it gone; waiting for Claude's next turn")
            activityRunning = false
            shown = nil
            endedByHandAt = Date()
        } else if !gained.isEmpty, let desired {
            // A new activity reported where to send its updates: bring it up to date, and follow it if
            // this Mac had lost track of it.
            activityRunning = true
            send(update: desired, urgent: false, force: true)
        }
        readCommands()
        environment.agent.phoneDoneChanged()
    }

    // MARK: Sharing the room with Mochi Pocket

    @ObservationIgnored private var publishedLook: String?
    @ObservationIgnored private var publishedMirror: ClaudeMirror?
    @ObservationIgnored private var mirrorPublishedAt = Date.distantPast
    @ObservationIgnored private var applyingPhoneInteraction = false
    @ObservationIgnored private var handledInteractions = Set<String>()

    /// The look (names, colours, room) and what Claude is doing, so the iPhone's room matches this one.
    private func publishShared() {
        let look = PetLook(settings: environment.settingsStore.settings,
                           friendshipLevel: environment.world.progress.friendshipLevel).json
        if look != publishedLook {
            publishedLook = look
            link.set(look, for: .look)
        }
        var mirror = ClaudeMirror.from(sessions: environment.world.sessions)
        mirror.resting = environment.world.macResting
        // A new phase goes out within seconds, a different tool alone only now and then (it only sets the companion's
        // mood on the phone).
        let spacing: TimeInterval = mirror.phase == publishedMirror?.phase && mirror.resting == publishedMirror?.resting ? 20 : 4
        if mirror != publishedMirror, Date().timeIntervalSince(mirrorPublishedAt) >= spacing {
            publishedMirror = mirror
            mirrorPublishedAt = Date()
            var value: [String: Any] = ["phase": mirror.phase, "resting": mirror.resting, "at": Date().timeIntervalSince1970]
            if let category = mirror.category { value["category"] = category }
            write(value, for: .claude)
        }
    }

    /// Petting, play and treats on the Mac show on the iPhone too.
    func userInteracted(_ kind: PetInteraction) {
        guard !applyingPhoneInteraction else { return }
        write(["id": UUID().uuidString, "kind": kind.rawValue, "at": Date().timeIntervalSince1970], for: .macInteraction)
    }

    private func readPhoneInteraction() {
        guard let data = link.dictionary(.phoneInteraction), let id = data["id"] as? String, !handledInteractions.contains(id),
              let at = data["at"] as? Double, Date().timeIntervalSince1970 - at < 90,
              let raw = data["kind"] as? String, let kind = PetInteraction(rawValue: raw) else { return }
        handledInteractions.insert(id)
        applyingPhoneInteraction = true
        environment.world.interact(kind)
        applyingPhoneInteraction = false
    }

    // MARK: Claude's summaries

    /// Where the iPhone takes ordinary notifications (finished turns, with a Reply action).
    private(set) var deviceToken: String?
    private(set) var lastSummary: String?
    @ObservationIgnored private var reports = SessionReports()
    @ObservationIgnored private var summaries: [String: (summary: TurnSummary, files: [String], at: Date)] = [:]
    /// The last few notes per session, so the next summary knows what the session is about.
    @ObservationIgnored private var notes: [String: [String]] = [:]
    @ObservationIgnored private var publishedSessions: String?
    @ObservationIgnored private var sessionsPublishedAt = Date.distantPast
    @ObservationIgnored private var summaryFlag: Bool?

    /// Every live hook event, before the world sees it: collects each turn's changed files and,
    /// when Claude stops, summarizes the turn for the iPhone.
    func record(_ wire: WireEvent) {
        guard settings.shareSummaries, let report = reports.record(wire) else { return }
        summarize(report)
    }

    private func summarize(_ report: TurnReport) {
        let prompt = TurnSummarizer.prompt(for: report, earlier: notes[report.sessionID] ?? [])
        let executable = environment.integration.installation?.executable.path
        let directory = environment.paths.assistantDirectory
        let processEnvironment = BrainSession.environment()
        Task {
            var summary: TurnSummary?
            if let executable, report.message != nil, BridgePaths.ensurePrivateDirectory(directory) {
                let output = await TurnSummaryRunner.run(prompt: prompt, executable: executable, directory: directory,
                                                         environment: processEnvironment)
                summary = output.flatMap(TurnSummarizer.parse)
            }
            self.deliver(summary ?? TurnSummarizer.fallback(report), for: report)
        }
    }

    private func deliver(_ summary: TurnSummary, for report: TurnReport) {
        guard settings.shareSummaries else { return }
        notes[report.sessionID] = Array(((notes[report.sessionID] ?? []) + [summary.done]).suffix(3))
        summaries[report.sessionID] = (summary, report.files, report.at)
        lastSummary = "\(report.project): \(summary.done)"
        publishSessions(force: true)
        guard canPush else { return }
        if settings.notifyOnlyWhenAway, Self.secondsSinceInput() < 180 { return }
        let card = PhoneSessionCard(id: report.sessionID, project: report.project, phase: "done", summary: summary,
                                    files: Array(report.files.prefix(12)), finishedAt: report.at.timeIntervalSince1970.rounded())
        deliver(PhoneAlertPayload.turnFinished(card), priority: 10, label: "Summary sent", pushType: "alert")
    }

    /// Mochi's agent news (new mail, a meeting soon, tasks due) as an ordinary notification.
    /// Returns false when no phone can be reached (this Mac isn't paired).
    @discardableResult
    func sendAgentNews(title: String, body: String, pending: AgentPending?, quietIfKnown: Bool) -> Bool {
        guard canPush else { return false }
        deliver(PhoneAlertPayload.agentNews(title: title, body: body, pending: pending, quietIfKnown: quietIfKnown),
                priority: 10, label: "News sent", pushType: "alert")
        return true
    }

    /// Mochi Cloud's "check now" link for Mochi Pocket (its token can only start that one task); nil removes it.
    func publishCloudTrigger(url: String?, token: String?) {
        if let url, let token {
            link.set(["url": url, "token": token], for: .cloud)
        } else {
            link.set(nil, for: .cloud)
        }
    }

    /// What you marked done in Mochi Pocket.
    var phoneDone: AgentDoneList? {
        guard let json = link.string(.phoneDone) else { return nil }
        return AgentDoneList.decode(json)
    }

    /// What's done on this Mac (and everything it heard of), so Mochi Pocket hides it too.
    func publishMacDone(_ list: AgentDoneList) {
        let json = list.json
        guard link.string(.macDone) != json else { return }
        link.set(json, for: .macDone)
    }

    /// Mochi Pocket's Pending card (what's waiting for you), through Mochi Link.
    func publishAgentPending(_ json: String) {
        link.set(json, for: .agent)
    }

    /// Mochi Pocket's list of sessions: each live session's phase and the summary of its last turn.
    private func publishSessions(force: Bool = false) {
        var payload = PhoneSessions(enabled: settings.shareSummaries)
        if settings.shareSummaries {
            let live = environment.world.sessions.filter { !$0.isSimulated && $0.endedAt == nil && $0.phase != .ended }
            summaries = summaries.filter { entry in live.contains { $0.id == entry.key } }
            payload.sessions = live.sorted { $0.lastEventAt > $1.lastEventAt }.prefix(6).map { session in
                let entry = summaries[session.id]
                return PhoneSessionCard(id: session.id, project: session.project?.displayName ?? "Claude",
                                        phase: LiveActivityPlanner.phase(of: session), summary: entry?.summary,
                                        files: Array((entry?.files ?? []).prefix(12)), finishedAt: entry?.at.timeIntervalSince1970.rounded(),
                                        phaseSince: Self.phaseStart(of: session).timeIntervalSince1970.rounded())
            }
        }
        let json = payload.json
        guard json != publishedSessions, force || Date().timeIntervalSince(sessionsPublishedAt) >= 3 else { return }
        publishedSessions = json
        sessionsPublishedAt = Date()
        payload.updatedAt = Date().timeIntervalSince1970.rounded(.up)
        link.set(payload.json, for: .sessions)
    }

    /// The hook helper includes Claude's words only while this file exists.
    private func syncSummaryFlag() {
        let on = settings.shareSummaries && paired
        guard on != summaryFlag else { return }
        summaryFlag = on
        let url = environment.paths.summariesFlagFile
        if on {
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        } else {
            try? FileManager.default.removeItem(at: url)
            reports = SessionReports()
            summaries = [:]
            notes = [:]
            lastSummary = nil
        }
        publishSessions(force: true)
    }

    /// When the session's current phase began (stable while the phase lasts, so the list rarely changes).
    static func phaseStart(of session: SessionSnapshot) -> Date {
        switch session.phase {
        case .promptSubmitted, .thinking, .runningTool: return session.turnStartedAt ?? session.lastEventAt
        case .turnCompleted: return session.lastTurnCompletedAt ?? session.lastEventAt
        default: return session.lastEventAt
        }
    }

    static func secondsSinceInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .mouseMoved)
    }

    /// The Live Activity's words for a finished turn: Claude's summary, when there is a fresh one.
    private func withSummary(_ state: LiveActivityState) -> LiveActivityState {
        guard settings.shareSummaries, state.phase == "done", let session = LiveActivityPlanner.focus(environment.world.sessions),
              let entry = summaries[session.id], entry.at.timeIntervalSince1970 >= state.since - 10 else { return state }
        var state = state
        state.detail = entry.summary.done.count > 90 ? String(entry.summary.done.prefix(89)) + "…" : entry.summary.done
        return state
    }

    // MARK: Commands from the iPhone

    /// What you told Mochi on the iPhone runs here through Ask Mochi, as if typed on the Mac.
    private func readCommands() {
        readPhoneInteraction()
        guard settings.acceptCommands else { return }
        if let command = link.dictionary(.command), let id = command["id"] as? String, !handledCommands.contains(id) {
            let age = Date().timeIntervalSince1970 - ((command["at"] as? Double) ?? 0)
            Self.linkLog.notice("phone command \(id.prefix(8), privacy: .public), \(Int(age))s old\(age >= 180 ? " (too old, ignored)" : "", privacy: .public)")
        }
        if let command = link.dictionary(.command), let id = command["id"] as? String,
           let text = (command["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
           let at = command["at"] as? Double, Date().timeIntervalSince1970 - at < 180, !handledCommands.contains(id) {
            handledCommands.insert(id)
            UserDefaults.standard.set(Array(handledCommands.suffix(30)), forKey: "phoneHandledCommands")
            lastCommand = text
            write(["id": id, "state": "working", "at": Date().timeIntervalSince1970], for: .reply)
            // A reply from a session card or a notification goes to that session.
            let target = (command["project"] as? String).map { AssistantController.Target(project: $0, sessionID: command["session"] as? String) }
            environment.assistant.run(text, headless: true, spoken: (command["typed"] as? Bool) != true, origin: .phone(id), target: target)
        }
        if let verdict = link.dictionary(.verdict), let id = verdict["id"] as? String, id == pendingApprovalID,
           let allow = verdict["allow"] as? Bool {
            pendingApprovalID = nil
            environment.assistant.answerFromPhone(approvalID: id, allow: allow)
        }
    }

    /// Mochi's answer to a command from the iPhone.
    func reply(to commandID: String, text: String, ok: Bool) {
        write(["id": commandID, "state": ok ? "done" : "failed", "text": text, "at": Date().timeIntervalSince1970], for: .reply)
    }

    /// Shows the approval card on the iPhone too; the first answer (Mac or iPhone) wins.
    func mirrorApproval(id: String, commandID: String, target: String, project: String?, message: String) {
        pendingApprovalID = id
        var request: [String: Any] = ["id": id, "command": commandID, "target": target, "message": message,
                                      "at": Date().timeIntervalSince1970]
        if let project { request["project"] = project }
        write(request, for: .approval)
    }

    func clearApproval() {
        guard pendingApprovalID != nil || link.dictionary(.approval) != nil else { return }
        pendingApprovalID = nil
        link.set(nil, for: .approval)
    }

    private func write(_ value: [String: Any], for key: LinkKey) {
        link.set(value, for: key)
    }

    // MARK: Following Claude

    private func tick() {
        publishShared()
        syncSummaryFlag()
        publishSessions()
        if let testUntil, Date() < testUntil { return }
        testUntil = nil
        guard settings.enabled, canPush else {
            if activityRunning, let shown { send(end: shown) }
            return
        }
        let state = LiveActivityPlanner.state(sessions: environment.world.sessions,
                                              shareProjectNames: settings.shareProjectNames, now: Date()).map(withSummary)
        desired = state
        guard let state else {
            if activityRunning, let shown { send(end: shown) }
            return
        }
        if !activityRunning {
            // Ended by hand: back for Claude's next prompt, or when Claude needs you.
            if let endedByHandAt, state.since <= endedByHandAt.timeIntervalSince1970 { return }
            if state.phase == "working" || state.phase == "waiting" { send(start: state) }
            return
        }
        let sinceLast = Date().timeIntervalSince(lastSentAt)
        if !state.sameContent(as: shown) {
            let phaseChanged = state.phase != shown?.phase
            if phaseChanged || sinceLast >= Self.quietUpdateInterval {
                // With summaries on, the notification that follows is the one that buzzes.
                let notifies = state.phase == "done" && settings.shareSummaries && deviceToken != nil
                send(update: state, urgent: state.isUrgentChange(from: shown) && !notifies, force: false)
            }
        } else if state.phase == "working", sinceLast >= Self.motionInterval {
            send(update: state, urgent: false, force: true)
        }
    }

    /// A one-off check from Settings: always starts a fresh Live Activity on the iPhone, so it works
    /// even when this Mac's idea of what's showing there is out of date.
    func sendTest() {
        guard paired else {
            lastResult = nil
            lastError = Self.pairFirst
            return
        }
        testUntil = Date().addingTimeInterval(60)
        endedByHandAt = nil
        send(start: LiveActivityState(phase: "working", title: "Hello from your Mac!", detail: "Through Mochi Link, end-to-end encrypted",
                                      since: Date().timeIntervalSince1970))
    }

    static let pairFirst = "Pair your iPhone first (Mochi Link, above): nothing reaches your phone until then."

    /// Settings › iPhone › Mochi Link: a sealed notification through the relay, to check the whole path.
    func sendTestNotification() {
        guard let relay = MochiLink.relay else { return }
        relay.sendAlert(["title": "Hello from \(LinkController.macName)", "subtitle": "Mochi Link test",
                         "body": "This notification came through your relay, end-to-end encrypted: only your phones could read it.",
                         "userInfo": [:] as [String: Any]], category: nil, threadId: nil)
        lastResult = "Test notification sent through Mochi Link"
        lastError = nil
    }

    /// Ends it and takes it off the Lock Screen right away (a dismissal date in the past).
    func endNow() {
        testUntil = nil
        endedByHandAt = Date()
        send(end: shown ?? LiveActivityState(phase: "idle", title: "See you soon", since: Date().timeIntervalSince1970), dismissAfter: -60)
        if !paired {
            lastResult = nil
            lastError = Self.pairFirst
        } else if updateTokens.isEmpty {
            lastResult = nil
            lastError = "Your iPhone hasn't shared this Live Activity's address yet, so it closes when Mochi Pocket next opens."
        }
    }

    // MARK: Pushes

    /// Pushes can go out: this Mac is paired with Mochi Link. The relay holds the push key and the phones' addresses.
    var canPush: Bool { paired }

    /// Mochi Link (docs/MOCHI_LINK_PLAN.md 4.6.1): alerts sealed with the room key for the phone's notification extension,
    /// Live Activities with their title and detail sealed for the widget. Unpaired, nothing is sent.
    private func deliver(_ payload: Data, priority: Int, label: String, pushType: String = "liveactivity") {
        guard let relay = MochiLink.relay else {
            lastResult = nil
            lastError = Self.pairFirst
            return
        }
        if pushType == "liveactivity" {
            lastSentAt = Date()
            guard let raw = LinkCrypto.data(base64url: relay.credentials.key),
                  let apns = LinkPush.liveActivity(from: payload, liveActivityKey: LinkCrypto.liveActivityKey(from: SymmetricKey(data: raw)),
                                                   petName: environment.settingsStore.settings.petName) else {
                lastError = "Couldn't seal the Live Activity update."
                return
            }
            relay.sendLiveActivity(apns, priority: priority)
        } else {
            guard let alert = LinkPush.alert(from: payload) else { return }
            relay.sendAlert(alert.inner, category: alert.category, threadId: alert.threadId, priority: priority)
        }
        lastResult = "\(label) · through Mochi Link"
        lastError = nil
    }

    private func nextTimestamp() -> Date {
        // Each push needs a newer timestamp than the last, or iOS ignores it.
        lastTimestamp = max(lastTimestamp + 1, Date().timeIntervalSince1970.rounded())
        return Date(timeIntervalSince1970: lastTimestamp)
    }

    private func nextFrame(_ state: LiveActivityState) -> LiveActivityState {
        frameCounter += 1
        var moved = state
        moved.frame = frameCounter % 10
        return moved
    }

    private func send(start state: LiveActivityState) {
        let state = nextFrame(state)
        guard pushToStartToken != nil else {
            Self.linkLog.notice("live activity: can't start, no push-to-start address from the iPhone yet")
            lastError = "Open Mochi Pocket on your iPhone once, so it can share where to reach it."
            return
        }
        let payload = LiveActivityPayload.start(state, petName: environment.settingsStore.settings.petName,
                                                companionName: environment.settingsStore.settings.companionName, timestamp: nextTimestamp())
        activityRunning = true
        activityStartedAt = Date().timeIntervalSince1970
        shown = state
        Self.linkLog.notice("live activity: start (\(state.phase, privacy: .public))")
        deliver(payload, priority: 10, label: "Started on your iPhone")
    }

    private func send(update state: LiveActivityState, urgent: Bool, force: Bool) {
        guard force || !state.sameContent(as: shown) else { return }
        let state = nextFrame(state)
        shown = state
        guard !updateTokens.isEmpty else { return }   // sent once the iPhone shares the activity's address
        let payload = LiveActivityPayload.update(state, timestamp: nextTimestamp(), alert: urgent)
        deliver(payload, priority: urgent || state.phase != "working" ? 10 : 5, label: "Updated: \(state.title)")
    }

    /// Claude's own finish stays on the Lock Screen a few minutes; the Settings button removes it at once.
    private func send(end state: LiveActivityState, dismissAfter: TimeInterval = 180) {
        Self.linkLog.notice("live activity: end (\(state.phase, privacy: .public), dismissed after \(Int(dismissAfter))s)")
        activityRunning = false
        shown = nil
        // Mochi Pocket also closes it the next time it runs, in case the push can't reach it.
        let now = Date().timeIntervalSince1970
        write(["at": now, "since": state.since, "dismissAt": now + max(0, dismissAfter)], for: .activityEnded)
        guard !updateTokens.isEmpty else { return }
        deliver(LiveActivityPayload.end(state, timestamp: nextTimestamp(), dismissAfter: dismissAfter), priority: 10, label: "Ended")
    }

    // MARK: Development

    private func registerDebugHooks() {
        environment.debug.register("phone") { [weak self] argument in
            switch argument {
            case "test": self?.sendTest()
            case "end": self?.endNow()
            case "read": self?.readTokens()
            default: break
            }
        }
        environment.debug.registerState("phone") { [weak self] in
            guard let self else { return NSNull() }
            return [
                "enabled": self.settings.enabled, "paired": self.paired, "pushToStart": self.pushToStartToken != nil,
                "updateTokens": self.updateTokens.count, "running": self.activityRunning, "shown": self.shown?.phase ?? "",
                "lastResult": self.lastResult ?? "", "lastError": self.lastError ?? "",
            ]
        }
    }
}
