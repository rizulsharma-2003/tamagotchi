import CryptoKit
import Foundation

/// Settings for Mochi's Live Activity on the user's iPhone (the Mochi Pocket app).
public struct PhoneSettings: Codable, Sendable, Equatable {
    public var enabled = false
    /// The APNs auth key's id; the key itself is kept in the Keychain.
    public var keyID = ""
    public var teamID = "CZDJF6N2RH"
    /// The iPhone app's bundle id; Live Activity pushes go to "<topic>.push-type.liveactivity".
    public var topic = "com.insideedge.mochi"
    /// Show project names on the iPhone. Off: only "Claude is working" and counts.
    public var shareProjectNames = false
    /// Development builds of the iPhone app use APNs' sandbox.
    public var sandbox = true
    /// Run what you tell Mochi on the iPhone (it arrives through your iCloud).
    public var acceptCommands = true
    /// When Claude finishes a turn, send the iPhone the project, the changed files and a short summary.
    public var shareSummaries = false
    /// Only notify the iPhone about finished turns while this Mac is idle.
    public var notifyOnlyWhenAway = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PhoneSettings()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? defaults.enabled
        keyID = (try? container.decodeIfPresent(String.self, forKey: .keyID)) ?? defaults.keyID
        teamID = (try? container.decodeIfPresent(String.self, forKey: .teamID)) ?? defaults.teamID
        topic = (try? container.decodeIfPresent(String.self, forKey: .topic)) ?? defaults.topic
        shareProjectNames = (try? container.decodeIfPresent(Bool.self, forKey: .shareProjectNames)) ?? defaults.shareProjectNames
        sandbox = (try? container.decodeIfPresent(Bool.self, forKey: .sandbox)) ?? defaults.sandbox
        acceptCommands = (try? container.decodeIfPresent(Bool.self, forKey: .acceptCommands)) ?? defaults.acceptCommands
        shareSummaries = (try? container.decodeIfPresent(Bool.self, forKey: .shareSummaries)) ?? defaults.shareSummaries
        notifyOnlyWhenAway = (try? container.decodeIfPresent(Bool.self, forKey: .notifyOnlyWhenAway)) ?? defaults.notifyOnlyWhenAway
    }
}

/// What the Live Activity shows. The keys match `MochiActivityAttributes.ContentState` in the
/// iPhone app exactly; they are the wire format.
public struct LiveActivityState: Codable, Sendable, Equatable {
    public var phase: String
    public var title: String
    public var detail: String?
    /// Unix time the current turn or wait began (drives the iPhone's live timer).
    public var since: Double
    /// Which of the phase's ten poses the iPhone shows. Live Activities can't animate by themselves,
    /// so every update moves this on and the system animates the change.
    public var frame: Int?

    public init(phase: String, title: String, detail: String? = nil, since: Double, frame: Int? = nil) {
        self.phase = phase
        self.title = title
        self.detail = detail
        self.since = since
        self.frame = frame
    }

    /// Same words and phase, whatever the pose.
    public func sameContent(as other: LiveActivityState?) -> Bool {
        guard let other else { return false }
        return phase == other.phase && title == other.title && detail == other.detail && since == other.since
    }

    /// Changes worth an urgent (screen-lighting) push rather than a quiet one.
    public func isUrgentChange(from previous: LiveActivityState?) -> Bool {
        guard let previous else { return true }
        return previous.phase != phase && ["waiting", "done", "error"].contains(phase)
    }
}

/// Decides what the Live Activity should show from the Claude sessions Mochi knows about.
public enum LiveActivityPlanner {
    /// nil when no live Claude session is worth showing (the activity should end).
    public static func state(sessions: [SessionSnapshot], shareProjectNames: Bool, now: Date,
                             doneLinger: TimeInterval = 4 * 60, idleLinger: TimeInterval = 2 * 60) -> LiveActivityState? {
        guard let session = focus(sessions) else { return nil }
        let project = shareProjectNames ? session.project?.displayName : nil
        func detail(_ parts: String?...) -> String? {
            let text = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return text.isEmpty ? nil : text
        }
        let turnStart = (session.turnStartedAt ?? session.lastEventAt).timeIntervalSince1970
        switch session.phase {
        case .promptSubmitted, .thinking, .runningTool:
            let tools = session.toolCallsThisTurn
            return LiveActivityState(phase: "working", title: "Claude is working",
                                     detail: detail(project, tools > 0 ? "\(tools) tool\(tools == 1 ? "" : "s")" : nil), since: turnStart)
        case .waitingForUser:
            let reason: String? = switch session.waitingFor {
            case .permission?: "wants your OK"
            case .some: "is waiting for you"
            case nil: nil
            }
            return LiveActivityState(phase: "waiting", title: "Claude needs you", detail: detail(project, reason),
                                     since: session.lastEventAt.timeIntervalSince1970)
        case .turnCompleted:
            let finished = session.lastTurnCompletedAt ?? session.lastEventAt
            guard now.timeIntervalSince(finished) < doneLinger else { return nil }
            return LiveActivityState(phase: "done", title: "Claude finished!", detail: detail(project),
                                     since: finished.timeIntervalSince1970)
        case .turnFailed:
            guard now.timeIntervalSince(session.lastEventAt) < doneLinger else { return nil }
            return LiveActivityState(phase: "error", title: "Claude hit a snag", detail: detail(project),
                                     since: session.lastEventAt.timeIntervalSince1970)
        case .idle, .ended:
            guard now.timeIntervalSince(session.lastEventAt) < idleLinger else { return nil }
            return LiveActivityState(phase: "idle", title: "Claude is idle", detail: detail(project),
                                     since: session.lastEventAt.timeIntervalSince1970)
        }
    }
}

extension LiveActivityPlanner {
    /// The session the Live Activity follows: one that needs you, then one at work, then the latest.
    public static func focus(_ sessions: [SessionSnapshot]) -> SessionSnapshot? {
        let live = sessions.filter { !$0.isSimulated && $0.endedAt == nil && $0.phase != .ended }
        func rank(_ session: SessionSnapshot) -> Int {
            switch session.phase {
            case .waitingForUser: return 5
            case .promptSubmitted, .thinking, .runningTool: return 4
            case .turnFailed: return 3
            case .turnCompleted: return 2
            case .idle, .ended: return 1
            }
        }
        return live.max(by: { (rank($0), $0.lastEventAt) < (rank($1), $1.lastEventAt) })
    }

    /// working · waiting · done · error · idle
    public static func phase(of session: SessionSnapshot) -> String {
        switch session.phase {
        case .promptSubmitted, .thinking, .runningTool: return "working"
        case .waitingForUser: return "waiting"
        case .turnCompleted: return "done"
        case .turnFailed: return "error"
        case .idle, .ended: return "idle"
        }
    }
}

/// A regular notification (`apns-push-type: alert`) when Claude finishes a turn. Mochi Pocket gives
/// it a Reply action that sends the session its next request.
public enum PhoneAlertPayload {
    public static let turnCategory = "claude-turn"

    /// The card rides along, so Mochi Pocket can show it as soon as the notification lands (iCloud can
    /// take minutes).
    public static func turnFinished(_ card: PhoneSessionCard) -> Data {
        let aps: [String: AnyJSON] = [
            "alert": ["title": .string(card.project), "subtitle": "Claude finished", "body": .string(card.summary?.done ?? "Claude finished.")],
            "sound": "default",
            "category": .string(turnCategory),
            "thread-id": .string(card.id),
        ]
        var payload: [String: AnyJSON] = ["aps": .object(aps), "session": .string(card.id), "project": .string(card.project)]
        if let data = try? JSONEncoder().encode(card), let json = AnyJSON.parse(data) { payload["card"] = json }
        return Data(AnyJSON.object(payload).jsonText.utf8)
    }
}

/// ActivityKit push payloads (`apns-push-type: liveactivity`).
public enum LiveActivityPayload {
    public static let attributesType = "MochiActivityAttributes"

    public static func start(_ state: LiveActivityState, petName: String, companionName: String, timestamp: Date) -> Data {
        var aps = base(state, event: "start", timestamp: timestamp)
        aps["attributes-type"] = .string(attributesType)
        aps["attributes"] = ["petName": .string(petName), "companionName": .string(companionName)]
        aps["alert"] = ["title": .string(state.title), "body": .string(state.detail ?? "\(petName) is watching Claude work")]
        aps["input-push-token"] = 1
        return encode(aps)
    }

    public static func update(_ state: LiveActivityState, timestamp: Date, alert: Bool) -> Data {
        var aps = base(state, event: "update", timestamp: timestamp)
        if alert {
            var alertBody: [String: AnyJSON] = ["title": .string(state.title)]
            if let detail = state.detail { alertBody["body"] = .string(detail) }
            if state.phase == "waiting" { alertBody["sound"] = "default" }
            aps["alert"] = .object(alertBody)
        }
        return encode(aps)
    }

    public static func end(_ state: LiveActivityState, timestamp: Date, dismissAfter: TimeInterval = 15 * 60) -> Data {
        var aps = base(state, event: "end", timestamp: timestamp)
        aps["dismissal-date"] = .number(timestamp.addingTimeInterval(dismissAfter).timeIntervalSince1970.rounded())
        return encode(aps)
    }

    private static func base(_ state: LiveActivityState, event: String, timestamp: Date) -> [String: AnyJSON] {
        var content: [String: AnyJSON] = ["phase": .string(state.phase), "title": .string(state.title), "since": .number(state.since)]
        if let detail = state.detail { content["detail"] = .string(detail) }
        if let frame = state.frame { content["frame"] = .number(Double(frame)) }
        return ["timestamp": .number(timestamp.timeIntervalSince1970.rounded()), "event": .string(event), "content-state": .object(content)]
    }

    private static func encode(_ aps: [String: AnyJSON]) -> Data {
        Data(AnyJSON.object(["aps": .object(aps)]).jsonText.utf8)
    }
}

/// The token APNs wants in `authorization: bearer …`: an ES256 JWT signed with the team's auth key.
public enum APNsToken {
    public enum Failure: Error, Equatable { case invalidKey, missingIdentifiers }

    public static func make(keyPEM: String, keyID: String, teamID: String, issuedAt: Date) throws -> String {
        guard !keyID.isEmpty, !teamID.isEmpty else { throw Failure.missingIdentifiers }
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM) else { throw Failure.invalidKey }
        let header = base64URL(Data(#"{"alg":"ES256","kid":"\#(keyID)"}"#.utf8))
        let claims = base64URL(Data(#"{"iss":"\#(teamID)","iat":\#(Int(issuedAt.timeIntervalSince1970))}"#.utf8))
        let signingInput = "\(header).\(claims)"
        let signature = try key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(base64URL(signature.rawRepresentation))"
    }

    /// Whether the text is a usable APNs auth key (a P-256 private key in PEM).
    public static func isValidKey(_ pem: String) -> Bool {
        (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
