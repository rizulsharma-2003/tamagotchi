import Foundation
import Observation
import TamagotchiCore

/// Talks to MacTamagotchi through Mochi Link (the relay, end-to-end encrypted; `PocketLink` pairs it): spoken
/// commands go to the Mac, its answers and approval requests come back. Only the words you said and Mochi's short
/// answers travel. Unpaired, nothing goes anywhere and the app works on its own.
@MainActor
@Observable
final class MacLink {
    static let shared = MacLink()

    enum State: Equatable { case sending, working, done, failed }

    struct Exchange: Identifiable, Equatable {
        let id: String
        var text: String
        /// The Claude session it was for, when it was a reply to one.
        var project: String?
        var state: State
        var reply: String?
        var sentAt: Date
    }

    struct Approval: Identifiable, Equatable {
        let id: String
        var target: String
        var project: String?
        var message: String
    }

    private(set) var exchanges: [Exchange] = []
    private(set) var approval: Approval?
    /// Claude's sessions on the Mac with the summary of each one's last turn (when the Mac shares them).
    private(set) var sessions: [PhoneSessionCard] = []
    /// nil until the Mac has said whether it shares summaries.
    private(set) var summariesShared: Bool?
    /// The Mac's list from the link, and finished turns that came with notifications: those arrive even while the
    /// app is closed, before it reconnects.
    private var listedJSON: String?
    private var listed = PhoneSessions(enabled: false)
    private var listedKnown = false
    private var pushed: [String: PhoneSessionCard] = [:]
    /// Last time the Mac wrote to the store (it answers every command it sees).
    private(set) var macSeenAt: Date?
    /// What Mochi's agent on the Mac says is waiting for you (nil until the Mac shares it).
    private(set) var agent: AgentPending?
    /// Mochi Cloud's "check now" link, when the Mac shares it (Settings › Agent › Mochi Cloud).
    private var cloudTrigger: (url: URL, token: String)?
    /// When "Check now" was handed to Mochi Cloud because the Mac didn't answer.
    private(set) var cloudAskedAt: Date?
    /// Who made the Pending card's latest update: "mac" or "cloud".
    private(set) var lastCheckedBy: String?
    /// The last time Mochi Cloud's news reached this phone (kept across launches).
    private(set) var cloudSeenAt: Date? = UserDefaults.standard.object(forKey: "cloudSeenAt") as? Date
    var cloudAvailable: Bool { cloudTrigger != nil }
    /// Why the last request to Mochi Cloud didn't go through, if it didn't.
    private(set) var cloudError: String?
    /// "Check now" goes straight to Mochi Cloud (Settings › Mochi Cloud); off: your Mac first.
    var checkNowUsesCloud: Bool { UserDefaults.standard.object(forKey: "checkNowUsesCloud") as? Bool ?? true }
    /// Mochi Cloud was asked a moment ago and its answer hasn't arrived yet.
    var cloudChecking: Bool {
        guard let asked = cloudAskedAt, Date().timeIntervalSince(asked) < 240 else { return false }
        return (agent?.lookedAt ?? 0) < asked.timeIntervalSince1970
    }

    /// "Check now", answered in the cloud: works the same whether the Mac is on, asleep or offline.
    func checkInCloud() {
        guard let trigger = cloudTrigger, !cloudChecking else { return }
        Task { await fireCloud(trigger) }
    }

    private var linkStore: LinkStore { MochiLink.store }
    private var started = false
    private var answeredApprovals = Set<String>()


    var current: Exchange? { exchanges.last }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: .linkStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        read()
    }

    /// Sends a request to the Mac: for Mochi, or (with `project`) for that Claude session. Returns its id.
    @discardableResult
    func send(_ text: String, project: String? = nil, session: String? = nil, typed: Bool = false) -> String {
        let id = UUID().uuidString
        exchanges.append(Exchange(id: id, text: text, project: project, state: .sending, sentAt: Date()))
        if exchanges.count > 6 { exchanges.removeFirst(exchanges.count - 6) }
        var command: [String: Any] = ["id": id, "text": text, "at": Date().timeIntervalSince1970, "typed": typed]
        if let project { command["project"] = project }
        if let session { command["session"] = session }
        linkStore.set(command, for: .command)
        log("sent \(id.prefix(8))\(project.map { " to \($0)" } ?? ""): \(text)")
        return id
    }

    /// A finished turn from a notification, shown before the link catches up.
    func merge(_ card: PhoneSessionCard) {
        guard let finished = card.finishedAt, finished > (pushed[card.id]?.finishedAt ?? 0) else { return }
        pushed[card.id] = card
        log("summary from a notification: \(card.project)")
        rebuildSessions()
    }

    /// The newest Pending card, whether it came through the link or with a notification. An hourly Mochi Cloud
    /// card only adds what it found that hour.
    func mergeAgent(_ pending: AgentPending) {
        guard agent == nil || (pending.updatedAt ?? 0) > (agent?.updatedAt ?? 0) else { return }
        let merged = agent.map { $0.merging(pending) } ?? pending
        guard merged != agent else { return }
        agent = merged
        UpdatesStore.shared.cardChanged(merged)
        let fromCloud = pending.origin?.hasPrefix("cloud") == true
        lastCheckedBy = fromCloud ? "cloud" : "mac"
        if fromCloud {
            cloudSeenAt = Date()
            UserDefaults.standard.set(cloudSeenAt, forKey: "cloudSeenAt")
        }
        log("pending\(pending.origin.map { " from \($0)" } ?? ""): \(merged.enabled ? "\(merged.items.count) item(s)" : "not shared")")
    }

    /// When the Mac hasn't picked up "Check now" after `seconds` (it's off, asleep or offline), asks Mochi Cloud.
    func askCloudIfMacSilent(for exchangeID: String, after seconds: Double = 15) {
        guard cloudTrigger != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard let exchange = exchanges.first(where: { $0.id == exchangeID }), exchange.state == .sending,
                  let trigger = cloudTrigger else { return }
            await fireCloud(trigger)
        }
    }

    /// The draft request on its way to Mochi Cloud, and how it went.
    private(set) var draftAskedAt: Date?

    var draftsAvailable: Bool { cloudTrigger != nil }

    /// "Draft reply": Mochi Cloud writes a reply to that thread into Gmail Drafts (never sends it) and notifies
    /// this iPhone. Returns why it couldn't be asked, or nil.
    func draftReply(threadID: String, note: String) async -> String? {
        guard let trigger = cloudTrigger else { return "Set up Mochi Cloud on \(PocketLink.shared.host.yours) first (Settings › Agent › Mochi Cloud)." }
        guard !threadID.isEmpty, threadID.allSatisfy({ $0.isLetter || $0.isNumber }) else { return "That email can't be found." }
        // One line of plain words: no angle brackets, so it can't be mistaken for the request's wrapper.
        let words = note.components(separatedBy: .newlines).joined(separator: " ")
            .filter { $0 != "<" && $0 != ">" }.trimmingCharacters(in: .whitespaces)
        let text = "draft \(threadID)" + (words.isEmpty ? "" : " " + String(words.prefix(300)))
        let error = await fireCloud(trigger, text: text)
        if error == nil { draftAskedAt = Date() }
        return error
    }

    /// Siri's "Check": Mochi Cloud looks now. Returns why it couldn't, or nil.
    func checkInCloudNow() async -> String? {
        guard let trigger = cloudTrigger else { return "Mochi Cloud isn't set up yet. Set it up on \(PocketLink.shared.host.yours) (Settings › Agent)." }
        return await fireCloud(trigger)
    }

    @discardableResult
    private func fireCloud(_ trigger: (url: URL, token: String), text: String = "check now") async -> String? {
        var request = URLRequest(url: trigger.url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trigger.token)", forHTTPHeaderField: "Authorization")
        request.setValue("experimental-cc-routine-2026-04-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        let checking = text == "check now"
        var problem: String?
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            log("asked Mochi Cloud (\(text.split(separator: " ").first ?? "")): HTTP \(status)")
            switch status {
            case 200..<300: problem = nil
            case 401, 403: problem = "Mochi Cloud refused the request. Save a fresh API token on \(PocketLink.shared.host.yours) (Settings › Agent › Mochi Cloud)."
            case 429: problem = "Mochi Cloud is busy (too many requests this hour). Try again in a few minutes."
            default: problem = "Couldn't reach Mochi Cloud (HTTP \(status))."
            }
        } catch {
            log("asking Mochi Cloud failed: \(error.localizedDescription)")
            problem = "Couldn't reach Mochi Cloud: \(error.localizedDescription)"
        }
        if checking {
            if problem == nil { cloudAskedAt = Date() }
            cloudError = problem
        }
        return problem
    }

    private func rebuildSessions() {
        let listedAt = listed.updatedAt ?? 0
        // Cards the Mac's list has caught up with (or that ended since) are no longer needed.
        pushed = pushed.filter { ($0.value.finishedAt ?? 0) >= listedAt }
        if !pushed.isEmpty {
            summariesShared = true
        } else {
            summariesShared = listedKnown ? listed.enabled : nil
        }
        guard summariesShared == true else {
            sessions = []
            return
        }
        var list = listed.enabled ? listed.sessions.map { card in pushed[card.id].map(card.merging) ?? card } : []
        let known = Set(list.map(\.id))
        list.insert(contentsOf: pushed.values.filter { !known.contains($0.id) }.sorted { ($0.finishedAt ?? 0) > ($1.finishedAt ?? 0) }, at: 0)
        sessions = Array(list.prefix(6))
    }

    #if DEBUG
    /// `-demoContent 1` (Simulator screenshots): sample mail, meetings, a Notion task and Claude sessions.
    func showDemoContent() {
        let now = Date().timeIntervalSince1970
        agent = AgentPending(
            enabled: true,
            headline: "A busy afternoon: the design review is at 4, and Priya is waiting on the October invoice.",
            items: [
                AgentNote(id: "cal:demo1", source: .calendar, title: "Design review", detail: "With Aditi and Sam · Google Meet",
                          important: true, at: now, due: now + 2 * 3600, link: "https://meet.google.com/abc-defg-hij"),
                AgentNote(id: "mail:demo1", source: .gmail, title: "Priya Sharma",
                          detail: "Can you send the October invoice today? Finance closes the books tomorrow.", important: true,
                          at: now - 1800, link: "https://mail.google.com/mail/u/0/#inbox/demo1", subject: "Invoice for October", vip: true),
                AgentNote(id: "mail:demo2", source: .gmail, title: "Aditi Rao", detail: "Shared the new onboarding flow; would love your notes before Friday.",
                          important: true, at: now - 3600, link: "https://mail.google.com/mail/u/0/#inbox/demo2", subject: "Onboarding v2 for review"),
                AgentNote(id: "notion:demo1", source: .notion, title: "Finish the launch checklist", detail: "Due today · Product",
                          important: false, at: now - 7200, due: now + 5 * 3600, link: "https://www.notion.so"),
                AgentNote(id: "mail:demo3", source: .gmail, title: "GitHub", detail: "1 new commit pushed to main.",
                          important: false, at: now - 9000, link: "https://mail.google.com/mail/u/0/#inbox/demo3", subject: "[tamagotchi] Mochi's own voice"),
            ],
            lookedAt: now - 300, updatedAt: now - 300)
        lastCheckedBy = "cloud"
        summariesShared = true
        sessions = [
            PhoneSessionCard(id: "demo-s1", project: "mac-Tamagotchi", phase: "working",
                             summary: TurnSummary(done: "Gave Mochi its own Kokoro voice and made Siri read reliably.", next: ["Push it to GitHub"]),
                             files: ["KokoroVoice.swift", "UpdatesReader.swift"], finishedAt: now - 600, phaseSince: now - 120),
            PhoneSessionCard(id: "demo-s2", project: "mochi-cloud", phase: "done",
                             summary: TurnSummary(done: "Drafted a reply to Priya in Gmail Drafts. Nothing was sent."),
                             files: [], finishedAt: now - 2400, phaseSince: now - 2400),
        ]
        exchanges = [Exchange(id: "demo-e1", text: "What's pending?", project: nil, state: .done,
                              reply: "Five things. The design review at 4 and Priya's invoice need you.", sentAt: Date().addingTimeInterval(-900))]
    }
    #endif

    /// Development builds keep a short log of the link in Documents (copied off with devicectl).
    func log(_ line: String) {
        #if DEBUG
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = folder.appendingPathComponent("link-log.txt")
        let entry = "\(Date().formatted(date: .omitted, time: .standard)) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
        #endif
    }

    func answer(_ approval: Approval, allow: Bool) {
        answeredApprovals.insert(approval.id)
        self.approval = nil
        linkStore.set(["id": approval.id, "allow": allow, "at": Date().timeIntervalSince1970], for: .verdict)
    }

    func read() {
        // Only a new list counts: an old one read again mustn't undo newer news from a notification.
        if let json = linkStore.string(.sessions), json != listedJSON, let shared = PhoneSessions.decode(json) {
            listedJSON = json
            listed = shared
            listedKnown = true
            log("sessions: \(shared.enabled ? shared.sessions.map { "\($0.project) \($0.phase)\($0.summary == nil ? "" : " +summary")" }.joined(separator: ", ") : "summaries off")")
            rebuildSessions()
        }
        if let json = linkStore.string(.agent), let pending = AgentPending.decode(json) { mergeAgent(pending) }
        if let json = linkStore.string(.macDone), let list = AgentDoneList.decode(json) {
            UpdatesStore.shared.applyMacDone(list)
        }
        if let cloud = linkStore.dictionary(.cloud), let link = cloud["url"] as? String, let url = URL(string: link),
           url.host == "api.anthropic.com", let token = cloud["token"] as? String, !token.isEmpty {
            cloudTrigger = (url, token)
        } else {
            cloudTrigger = nil
        }
        if let reply = linkStore.dictionary(.reply), let id = reply["id"] as? String,
           let index = exchanges.firstIndex(where: { $0.id == id }) {
            switch reply["state"] as? String {
            case "working": if exchanges[index].state == .sending { exchanges[index].state = .working }
            case "done": exchanges[index].state = .done
            case "failed": exchanges[index].state = .failed
            default: break
            }
            if let text = reply["text"] as? String, !text.isEmpty { exchanges[index].reply = text }
            macSeenAt = Date()
            log("mac \(id.prefix(8)) \(reply["state"] as? String ?? "?"): \(reply["text"] as? String ?? "")")
        }
        if let request = linkStore.dictionary(.approval), let id = request["id"] as? String,
           !answeredApprovals.contains(id), let at = request["at"] as? Double, Date().timeIntervalSince1970 - at < 120,
           let target = request["target"] as? String, let message = request["message"] as? String {
            approval = Approval(id: id, target: target, project: request["project"] as? String, message: message)
            macSeenAt = Date()
            log("approval asked: \(target): \(message)")
            #if DEBUG
            // Development check of the approval path: `-autoApprove <session>` answers for that session only.
            if let auto = UserDefaults.standard.string(forKey: "autoApprove"), !auto.isEmpty, target.hasPrefix(auto), let approval {
                log("auto-approved for \(auto)")
                answer(approval, allow: true)
            }
            #endif
        } else if let current = approval, linkStore.dictionary(.approval)?["id"] as? String != current.id {
            approval = nil
        }
    }
}
