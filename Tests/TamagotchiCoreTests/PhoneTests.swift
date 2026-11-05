import Foundation
import Testing
@testable import TamagotchiCore

@Suite("iPhone Live Activity")
struct PhoneTests {
    private func session(_ phase: SessionPhase, project: String = "mac-Tamagotchi", at: Date, tools: Int = 0,
                         waiting: AttentionKind? = nil, simulated: Bool = false) -> SessionSnapshot {
        var s = SessionSnapshot(id: UUID().uuidString, project: ProjectRef(displayName: project, key: project, path: nil),
                                firstSeen: at, lastEventAt: at, isSimulated: simulated)
        s.phase = phase
        s.turnStartedAt = at.addingTimeInterval(-30)
        s.toolCallsThisTurn = tools
        s.waitingFor = waiting
        if phase == .turnCompleted { s.lastTurnCompletedAt = at }
        return s
    }

    @Test func picksTheMostUrgentLiveSession() {
        let now = Date()
        let working = session(.runningTool, project: "api", at: now, tools: 3)
        let waiting = session(.waitingForUser, project: "web", at: now.addingTimeInterval(-60), waiting: .permission)
        let state = LiveActivityPlanner.state(sessions: [working, waiting], shareProjectNames: true, now: now)
        #expect(state?.phase == "waiting")
        #expect(state?.title == "Claude needs you")
        #expect(state?.detail == "web · wants your OK")
        let onlyWorking = LiveActivityPlanner.state(sessions: [working], shareProjectNames: true, now: now)
        #expect(onlyWorking?.detail == "api · 3 tools")
        #expect(onlyWorking?.since == working.turnStartedAt!.timeIntervalSince1970)
    }

    @Test func keepsProjectNamesPrivateByDefault() {
        let now = Date()
        let state = LiveActivityPlanner.state(sessions: [session(.runningTool, at: now, tools: 1)], shareProjectNames: false, now: now)
        #expect(state?.detail == "1 tool")
        let detail = state?.detail ?? ""
        #expect(detail.range(of: "Tamagotchi") == nil, "\(detail)")
    }

    @Test func endsAfterDoneOrIdleAndIgnoresSimulated() {
        let now = Date()
        #expect(LiveActivityPlanner.state(sessions: [session(.turnCompleted, at: now)], shareProjectNames: false, now: now)?.phase == "done")
        #expect(LiveActivityPlanner.state(sessions: [session(.turnCompleted, at: now.addingTimeInterval(-600))], shareProjectNames: false, now: now) == nil)
        #expect(LiveActivityPlanner.state(sessions: [session(.idle, at: now.addingTimeInterval(-600))], shareProjectNames: false, now: now) == nil)
        #expect(LiveActivityPlanner.state(sessions: [session(.runningTool, at: now, simulated: true)], shareProjectNames: false, now: now) == nil)
        #expect(LiveActivityPlanner.state(sessions: [], shareProjectNames: false, now: now) == nil)
    }

    @Test func urgentOnlyForPhaseChangesThatNeedAttention() {
        let working = LiveActivityState(phase: "working", title: "w", since: 1)
        #expect(LiveActivityState(phase: "waiting", title: "n", since: 2).isUrgentChange(from: working))
        #expect(!LiveActivityState(phase: "working", title: "w2", since: 1).isUrgentChange(from: working))
        #expect(LiveActivityState(phase: "working", title: "w", since: 1).isUrgentChange(from: nil))
    }

    @Test func payloadsMatchTheIPhoneApp() {
        let state = LiveActivityState(phase: "working", title: "Claude is working", detail: "2 tools", since: 1_800_000_000)
        let start = AnyJSON.parse(LiveActivityPayload.start(state, petName: "Mochi", companionName: "Patch",
                                                            timestamp: Date(timeIntervalSince1970: 1_800_000_100)))?["aps"]
        #expect(start?["event"]?.stringValue == "start")
        #expect(start?["attributes-type"]?.stringValue == "MochiActivityAttributes")
        #expect(start?["attributes"] == ["petName": "Mochi", "companionName": "Patch"])
        #expect(start?["content-state"] == ["phase": "working", "title": "Claude is working", "detail": "2 tools", "since": .number(1_800_000_000)])
        #expect(start?["timestamp"]?.numberValue == 1_800_000_100)
        #expect(start?["alert"]?["title"]?.stringValue == "Claude is working")
        #expect(start?["input-push-token"]?.numberValue == 1)
        var moving = state
        moving.frame = 7
        let framed = AnyJSON.parse(LiveActivityPayload.update(moving, timestamp: Date(), alert: false))?["aps"]
        #expect(framed?["content-state"]?["frame"]?.numberValue == 7)
        #expect(moving.sameContent(as: state))
        #expect(!LiveActivityState(phase: "done", title: "x", since: 1).sameContent(as: state))
        let quiet = AnyJSON.parse(LiveActivityPayload.update(state, timestamp: Date(), alert: false))?["aps"]
        #expect(quiet?["event"]?.stringValue == "update")
        #expect(quiet?["alert"] == nil)
        let waiting = LiveActivityState(phase: "waiting", title: "Claude needs you", since: 1)
        let loud = AnyJSON.parse(LiveActivityPayload.update(waiting, timestamp: Date(), alert: true))?["aps"]
        #expect(loud?["alert"]?["sound"]?.stringValue == "default")
        let end = AnyJSON.parse(LiveActivityPayload.end(state, timestamp: Date(timeIntervalSince1970: 100), dismissAfter: 60))?["aps"]
        #expect(end?["event"]?.stringValue == "end")
        #expect(end?["dismissal-date"]?.numberValue == 160)
        // "End It" removes it at once: a dismissal date in the past.
        let now = AnyJSON.parse(LiveActivityPayload.end(state, timestamp: Date(timeIntervalSince1970: 100), dismissAfter: -60))?["aps"]
        #expect(now?["dismissal-date"]?.numberValue == 40)
    }

    @Test func lookRoundTripsAndApplies() {
        var mac = AppSettings()
        mac.petName = "Biscuit"
        mac.petColor = .peach
        mac.theme = .spaceStation
        let look = PetLook(settings: mac, friendshipLevel: 4)
        let decoded = PetLook.decode(look.json)
        #expect(decoded == look)
        var phone = AppSettings()
        decoded?.apply(to: &phone)
        #expect(phone.petName == "Biscuit")
        #expect(phone.petColor == .peach)
        #expect(phone.theme == .spaceStation)
        #expect(decoded?.friendshipLevel == 4)
    }

    @Test func mirrorsWhatClaudeIsDoing() {
        let now = Date()
        #expect(ClaudeMirror.from(sessions: []) == ClaudeMirror(phase: "none"))
        #expect(ClaudeMirror.from(sessions: [session(.waitingForUser, at: now)]) == ClaudeMirror(phase: "waiting"))
        #expect(ClaudeMirror.from(sessions: [session(.thinking, at: now)]) == ClaudeMirror(phase: "working", category: "think"))
        #expect(ClaudeMirror.from(sessions: [session(.turnCompleted, at: now)]).phase == "done")
        #expect(ClaudeMirror.from(sessions: [session(.runningTool, at: now, simulated: true)]).phase == "none")
        #expect(ClaudeMirror.tool(for: "shell") == "Bash")
        #expect(ClaudeMirror.tool(for: nil) == "Edit")
    }

    @Test func settingsDefaultToOffAndDecodeTolerantly() {
        // Older settings also held an APNs key id, team, topic and sandbox flag: they're ignored now.
        let settings = AppSettings.decodeTolerantly(Data(#"{"phone":{"enabled":true,"keyID":"K1","teamID":"T1","sandbox":false,"shareSummaries":true}}"#.utf8))
        #expect(settings.phone.enabled)
        #expect(settings.phone.shareSummaries)
        #expect(settings.phone.acceptCommands)
        #expect(!AppSettings().phone.enabled)
        #expect(!AppSettings().phone.shareProjectNames)
    }
}
