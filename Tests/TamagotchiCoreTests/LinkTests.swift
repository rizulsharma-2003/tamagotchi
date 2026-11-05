import CryptoKit
import Foundation
import Testing
@testable import TamagotchiCore

/// Mochi Link's shared contract (docs/MOCHI_LINK_PLAN.md): the encryption every client must match, the pairing code,
/// the envelope, the key names, and sample payloads (`link-spec/fixtures`) that the Flutter apps decode too.
@Suite("Mochi Link")
struct LinkTests {
    private static let spec = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("link-spec")

    // MARK: Encryption

    private struct Vector: Decodable {
        var name, key, nonce, ad, plaintext, box: String
    }

    private func vectors() throws -> [Vector] {
        struct File: Decodable { var vectors: [Vector] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: Self.spec.appendingPathComponent("vectors.json"))).vectors
    }

    @Test("Sealing reproduces every shared vector, and opening returns the plaintext")
    func sharedVectors() throws {
        let list = try vectors()
        #expect(list.count >= 4)
        for vector in list {
            let key = SymmetricKey(data: try #require(LinkCrypto.data(base64url: vector.key)))
            let nonce = try #require(LinkCrypto.data(base64url: vector.nonce))
            let sealed = try LinkCrypto.seal(Data(vector.plaintext.utf8), ad: vector.ad, key: key, nonce: nonce)
            #expect(sealed.box == vector.box, "\(vector.name)")
            #expect(sealed.nonce == vector.nonce)
            let opened = LinkCrypto.open(sealed, ad: vector.ad, key: key)
            #expect(opened.map { String(decoding: $0, as: UTF8.self) } == vector.plaintext)
        }
    }

    @Test("A box won't open with another room, key name, id, sender or key, or with a flipped byte")
    func tamperingFails() throws {
        let key = LinkCrypto.newRoomKey()
        let ad = LinkCrypto.associatedData(room: "room_A", key: "command", id: "01JC", from: "dev_phone")
        let sealed = try LinkCrypto.seal(Data(#"{"text":"run the tests"}"#.utf8), ad: ad, key: key)
        #expect(LinkCrypto.open(sealed, ad: ad, key: key) != nil)
        for other in [LinkCrypto.associatedData(room: "room_B", key: "command", id: "01JC", from: "dev_phone"),
                      LinkCrypto.associatedData(room: "room_A", key: "reply", id: "01JC", from: "dev_phone"),
                      LinkCrypto.associatedData(room: "room_A", key: "command", id: "01JD", from: "dev_phone"),
                      LinkCrypto.associatedData(room: "room_A", key: "command", id: "01JC", from: "dev_cloud")] {
            #expect(LinkCrypto.open(sealed, ad: other, key: key) == nil)
        }
        #expect(LinkCrypto.open(sealed, ad: ad, key: LinkCrypto.newRoomKey()) == nil)
        var bytes = try #require(LinkCrypto.data(base64url: sealed.box))
        bytes[0] ^= 0x01
        #expect(LinkCrypto.open(.init(nonce: sealed.nonce, box: LinkCrypto.base64url(bytes)), ad: ad, key: key) == nil)
    }

    @Test("Each seal uses a fresh nonce")
    func freshNonces() throws {
        let key = LinkCrypto.newRoomKey()
        let first = try LinkCrypto.seal(Data("same".utf8), ad: "ad", key: key)
        let second = try LinkCrypto.seal(Data("same".utf8), ad: "ad", key: key)
        #expect(first.nonce != second.nonce)
        #expect(first.box != second.box)
    }

    @Test("The Live Activity key is derived, stable, and can't open what K sealed")
    func liveActivityKey() throws {
        let roomKey = SymmetricKey(data: Data(repeating: 7, count: 32))
        let derived = LinkCrypto.liveActivityKey(from: roomKey)
        #expect(derived.withUnsafeBytes { Data($0) } == LinkCrypto.liveActivityKey(from: roomKey).withUnsafeBytes { Data($0) })
        #expect(derived.withUnsafeBytes { Data($0) } != roomKey.withUnsafeBytes { Data($0) })
        let sealed = try LinkCrypto.seal(Data("command".utf8), ad: "ad", key: roomKey)
        #expect(LinkCrypto.open(sealed, ad: "ad", key: derived) == nil)
    }

    // MARK: Pairing and envelopes

    @Test("A pairing code survives the QR round trip, and incomplete codes are refused")
    func pairingCode() throws {
        let key = LinkCrypto.base64url(Data(repeating: 9, count: 32))
        let code = PairingCode(relay: "link.example.com", room: "room_5TQ9", invite: "inv_X1", key: key, name: "Rizul's MacBook & Mochi")
        #expect(code.url.absoluteString.hasPrefix("mochi://pair?v=1&"))
        #expect(PairingCode(url: code.url) == code)
        #expect(PairingCode(string: "  \(code.url.absoluteString)\n") == code)
        #expect(PairingCode(string: code.url.absoluteString.replacingOccurrences(of: "v=1", with: "v=2")) == nil)
        #expect(PairingCode(string: "mochi://pair?v=1&relay=r&room=x&invite=y&key=short") == nil)
        #expect(PairingCode(string: "https://example.com/pair?v=1") == nil)
    }

    @Test("The envelope keeps the wire names from the plan")
    func envelope() throws {
        let envelope = LinkEnvelope(op: .send, key: "command", id: "01JC", to: ["host"], at: 1_762_243_200, ttl: 600,
                                    push: .init(kind: "alert", priority: 10, collapse: "reply-01JC"),
                                    sealed: .init(nonce: "bm9uY2U", box: "Ym94"))
        let json = try #require(String(data: JSONEncoder().encode(envelope), encoding: .utf8))
        for field in [#""op":"send""#, #""key":"command""#, #""ttl":600"#, #""nonce":"bm9uY2U""#, #""box":"Ym94""#, #""v":1"#] {
            #expect(json.contains(field), "\(field)")
        }
        let back = try JSONDecoder().decode(LinkEnvelope.self, from: Data(json.utf8))
        #expect(back == envelope)
        #expect(back.sealed == LinkCrypto.Sealed(nonce: "bm9uY2U", box: "Ym94"))
    }

    // MARK: Keys

    @Test("Key names are the relay's, and each key has one writer")
    func keys() {
        // The relay's room keeps state under these names: they never change.
        #expect(LinkKey.allCases.map(\.rawValue) == ["look", "claude", "sessions", "agent", "cloud", "approval", "macDone",
                                                    "phoneDone", "activityEnded", "macInteraction", "phoneInteraction",
                                                    "command", "reply", "verdict", "pushToStart", "updateTokens",
                                                    "deviceToken", "tokensSavedAt"])
        #expect(LinkKey.command.kind == .message && LinkKey.look.kind == .state && LinkKey.deviceToken.kind == .registration)
        #expect(LinkKey.look.writer == "host" && LinkKey.cloud.writer == "host" && LinkKey.reply.writer == "host")
        #expect(LinkKey.phoneDone.writer == "pocket" && LinkKey.command.writer == "pocket" && LinkKey.pushToStart.writer == "pocket")
        // Every message goes to the other side.
        for key in LinkKey.allCases where key.kind == .message {
            #expect(key.relayTargets == [key.writer == "host" ? "pocket" : "host"], "\(key)")
        }
    }

    // MARK: Fixtures

    /// Sample payloads in the exact shapes the apps write, one file per key. Regenerate with
    /// `MOCHI_WRITE_LINK_FIXTURES=1 swift test --filter "Mochi Link"`.
    private static func samples() -> [LinkKey: Any] {
        var settings = AppSettings()
        settings.petName = "Mochi"
        let card = PhoneSessionCard(id: "session-1", project: "mac-Tamagotchi", phase: "done",
                                    summary: TurnSummary(done: "Gave Mochi its own voice.", next: ["Push it"]),
                                    files: ["KokoroVoice.swift"], finishedAt: 1_762_243_100, phaseSince: 1_762_243_000)
        let note = AgentNote(id: "mail:18c2", source: .gmail, title: "Priya Sharma", detail: "Can you send the October invoice?",
                             important: true, at: 1_762_243_000, link: "https://mail.google.com/mail/u/0/#inbox/18c2",
                             subject: "Invoice for October", vip: true)
        let done = AgentDoneList(ids: ["mail:18c2": 1_762_243_150])
        return [
            .look: PetLook(settings: settings, friendshipLevel: 3).json,
            .claude: ["phase": "working", "resting": false, "at": 1_762_243_200.0, "category": "edit"] as [String: Any],
            .sessions: PhoneSessions(enabled: true, sessions: [card], updatedAt: 1_762_243_200).json,
            .agent: AgentPending(enabled: true, headline: "Priya is waiting on the invoice.", items: [note],
                                 lookedAt: 1_762_243_000, updatedAt: 1_762_243_000).json,
            .cloud: ["url": "https://api.anthropic.com/v1/claude_code/routines/trig_example/fire", "token": "example-token"],
            .approval: ["id": "approval-1", "command": "cmd-1", "target": "session-1", "project": "mac-Tamagotchi",
                        "message": "Run the tests and push.", "at": 1_762_243_200.0] as [String: Any],
            .macDone: done.json,
            .phoneDone: done.json,
            .activityEnded: ["at": 1_762_243_200.0, "since": 1_762_242_000.0, "dismissAt": 1_762_243_500.0],
            .macInteraction: ["id": "int-1", "kind": "pet", "at": 1_762_243_200.0] as [String: Any],
            .phoneInteraction: ["id": "int-2", "kind": "treat", "at": 1_762_243_200.0] as [String: Any],
            .command: ["id": "cmd-1", "text": "What's pending?", "at": 1_762_243_200.0, "typed": true,
                       "project": "mac-Tamagotchi", "session": "session-1"] as [String: Any],
            .reply: ["id": "cmd-1", "state": "done", "text": "Five things are waiting.", "at": 1_762_243_210.0] as [String: Any],
            .verdict: ["id": "approval-1", "allow": true, "at": 1_762_243_220.0] as [String: Any],
        ]
    }

    @Test("Sample payloads for every state and message key decode with today's models")
    func fixtures() throws {
        let folder = Self.spec.appendingPathComponent("fixtures")
        let samples = Self.samples()
        if ProcessInfo.processInfo.environment["MOCHI_WRITE_LINK_FIXTURES"] == "1" {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (key, value) in samples {
                // JSON strings are stored as their JSON; dictionaries as an object.
                let object: Any = (value as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? value
                let data = try JSONSerialization.data(withJSONObject: ["key": key.rawValue,
                                                                       "storedAs": value is String ? "json-string" : "dictionary",
                                                                       "value": object],
                                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try data.write(to: folder.appendingPathComponent("\(key.rawValue).json"))
            }
        }
        let stateAndMessages = LinkKey.allCases.filter { $0.kind != .registration }
        #expect(Set(samples.keys) == Set(stateAndMessages))
        for key in stateAndMessages {
            let file = folder.appendingPathComponent("\(key.rawValue).json")
            let fixture = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], "\(key)")
            #expect(fixture["key"] as? String == key.rawValue)
            let value = try #require(fixture["value"])
            if fixture["storedAs"] as? String == "json-string" {
                let json = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
                switch key {
                case .look: #expect(PetLook.decode(json) != nil)
                case .sessions: #expect(PhoneSessions.decode(json)?.sessions.first?.summary?.done == "Gave Mochi its own voice.")
                case .agent: #expect(AgentPending.decode(json)?.items.first?.threadID == "18c2")
                case .macDone, .phoneDone: #expect(AgentDoneList.decode(json)?.ids["mail:18c2"] != nil)
                default: Issue.record("\(key) shouldn't be a JSON string")
                }
            } else {
                #expect(value is [String: Any], "\(key)")
            }
        }
    }
}

@Suite("Mochi Link relay client")
struct RelayClientTests {
    private let host = LinkCredentials(relay: "localhost:8787", room: "room_1", device: "dev_mac", secret: "s1",
                                       key: LinkCrypto.base64url(Data(repeating: 3, count: 32)), role: "host")

    @Test func onlyRevokedOrDeletedRoomsEndTheLink() {
        #expect(RelayLinkStore.refusedForGood(status: 401))
        #expect(RelayLinkStore.refusedForGood(status: 404))
        for status in [400, 403, 429, 500, 502, 503] { #expect(!RelayLinkStore.refusedForGood(status: status)) }
    }

    @Test("A frame is sealed for its room, key, id and sender, and carries routing only in the clear")
    func frames() throws {
        let key = SymmetricKey(data: Data(repeating: 3, count: 32))
        let command: [String: Any] = ["id": "cmd-1", "text": "What's pending?", "at": 1_762_243_200.0, "typed": true]
        let data = try #require(RelayLinkStore.frame(command, for: .command, credentials: host, key: key, id: "01JC"))
        let frame = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(frame["op"] as? String == "send")
        #expect(frame["key"] as? String == "command")
        #expect(frame["to"] as? [String] == ["host"])
        #expect(frame["ttl"] as? Int == 600)
        #expect(!String(decoding: data, as: UTF8.self).contains("pending"))
        let opened = try #require(RelayLinkStore.open(data, credentials: host, from: "dev_mac", key: key) as? [String: Any])
        #expect(opened["text"] as? String == "What's pending?")
        #expect(opened["typed"] as? Bool == true)
        // Claiming another sender breaks it.
        #expect(RelayLinkStore.open(data, credentials: host, from: "dev_other", key: key) == nil)
        // State is a put, to everyone; a JSON-string value survives as a string.
        let look = try #require(RelayLinkStore.frame(#"{"petName":"Mochi"}"#, for: .look, credentials: host, key: key))
        let lookFrame = try #require(try JSONSerialization.jsonObject(with: look) as? [String: Any])
        #expect(lookFrame["op"] as? String == "put" && lookFrame["to"] == nil)
        #expect(RelayLinkStore.open(look, credentials: host, from: "dev_mac", key: key) as? String == #"{"petName":"Mochi"}"#)
        // Clearing state sends null.
        let cleared = try #require(RelayLinkStore.frame(nil, for: .approval, credentials: host, key: key))
        #expect(RelayLinkStore.open(cleared, credentials: host, from: "dev_mac", key: key) is NSNull)
    }

    @Test("Frames sealed by the Dart client (flutter/packages/mochi_link) open here, and only from their sender")
    func dartFrames() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("flutter/packages/mochi_link/test/fixtures/dart_frames.json")
        let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let credentials = try JSONDecoder().decode(LinkCredentials.self, from: JSONSerialization.data(withJSONObject: file["credentials"] ?? [:]))
        let key = SymmetricKey(data: try #require(LinkCrypto.data(base64url: credentials.key)))
        let frames = try #require(file["frames"] as? [[String: Any]])
        #expect(frames.count == 3)
        for item in frames {
            let frame = Data(try #require(item["frame"] as? String).utf8)
            let opened = RelayLinkStore.open(frame, credentials: credentials, from: credentials.device, key: key)
            #expect(NSDictionary(dictionary: ["v": opened ?? "unopened"]) == NSDictionary(dictionary: ["v": item["value"] ?? NSNull()]))
            #expect(RelayLinkStore.open(frame, credentials: credentials, from: "dev_other", key: key) == nil)
        }
    }

    @Test("Messages go to the right role, state to everyone")
    func targets() {
        #expect(LinkKey.command.relayTargets == ["host"] && LinkKey.verdict.relayTargets == ["host"])
        #expect(LinkKey.reply.relayTargets == ["pocket"] && LinkKey.activityEnded.relayTargets == ["pocket"])
        for key in LinkKey.allCases where key.kind != .message { #expect(key.relayTargets == nil && key.relayTTL == nil) }
    }

    @Test("The relay client reads its own writes and refuses a bad key")
    func ownWrites() {
        let relay = RelayLinkStore(credentials: host)!
        relay.set("hello", for: .look)
        #expect(relay.string(.look) == "hello")
        relay.set(nil, for: .look)
        #expect(relay.value(.look) == nil)
        var broken = host
        broken.key = "short"
        #expect(RelayLinkStore(credentials: broken) == nil)
    }

    @Test("Unpaired, a device keeps its own writes and nothing goes anywhere")
    func local() {
        let local = LocalLinkStore()
        local.set("hello", for: .look)
        local.set(["id": "cmd-1"], for: .command)
        #expect(local.string(.look) == "hello" && local.dictionary(.command)?["id"] as? String == "cmd-1")
        local.set(nil, for: .look)
        #expect(local.value(.look) == nil)
    }

    @Test("Pairing carries a device's own state and push addresses over, never messages or another device's keys")
    func carryOver() throws {
        let phone = LocalLinkStore([.pushToStart: "ab12", .updateTokens: ["act-1": "cd34"], .phoneDone: "{}",
                                    .command: ["id": "cmd-1"], .look: "a look"])
        #expect(Set(MochiLink.carriedValues(from: phone, role: "pocket").keys) == [.pushToStart, .updateTokens, .phoneDone])
        // No role given: everything but messages (an unpaired store holds only its own writes).
        #expect(Set(MochiLink.carriedValues(from: phone, role: nil).keys) == [.pushToStart, .updateTokens, .phoneDone, .look])

        // Unpairing from the relay: only what this device's role writes.
        let relay = try #require(RelayLinkStore(credentials: host))
        relay.set(#"{"petName":"Mochi"}"#, for: .look)
        relay.set(["url": "https://api.anthropic.com/x/fire", "token": "t"], for: .cloud)
        relay.set(["id": "r-1", "state": "done"], for: .reply)
        relay.set("the phone's list", for: .phoneDone)
        let fromRelay = MochiLink.carriedValues(from: relay, role: nil)
        #expect(Set(fromRelay.keys) == [.look, .cloud])
        #expect(fromRelay[.look] as? String == #"{"petName":"Mochi"}"#)
    }

    @Test("Switching the link announces a change and a presence change") @MainActor
    func switchingAnnounces() async {
        final class Heard: @unchecked Sendable {
            var change = false
            var presence = false
        }
        let heard = Heard()
        let observers = [
            NotificationCenter.default.addObserver(forName: .linkStoreDidChange, object: nil, queue: .main) { _ in heard.change = true },
            NotificationCenter.default.addObserver(forName: .linkPresenceDidChange, object: nil, queue: .main) { _ in heard.presence = true },
        ]
        defer { observers.forEach { NotificationCenter.default.removeObserver($0) } }
        MochiLink.use(nil)
        #expect(MochiLink.relay == nil && MochiLink.store is LocalLinkStore)
        for _ in 0..<100 where !(heard.change && heard.presence) { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(heard.change && heard.presence)
    }
}

/// Against the real relay: `MOCHI_LINK_LIVE=mochi-link.spike01.workers.dev swift test --filter LiveRelayTests`.
@Suite("Mochi Link live relay", .enabled(if: ProcessInfo.processInfo.environment["MOCHI_LINK_LIVE"] != nil))
struct LiveRelayTests {
    private func wait(_ seconds: Double = 10, until condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test("A paired phone and Mac exchange a sealed command and reply, and see each other online")
    func roundTrip() async throws {
        let relay = try #require(ProcessInfo.processInfo.environment["MOCHI_LINK_LIVE"])
        let hostCredentials = try await LinkPairing.createRoom(relay: relay, platform: "macOS", name: "Test Mac")
        defer { Task { try? await LinkPairing.deleteRoom(hostCredentials) } }
        let code = try await LinkPairing.invite(hostCredentials, hostName: "Test Mac")
        let phoneCredentials = try await LinkPairing.join(try #require(PairingCode(url: code.url)), role: "pocket",
                                                          platform: "iOS", name: "Test iPhone")
        #expect(phoneCredentials.key == hostCredentials.key && phoneCredentials.peerName == "Test Mac")
        // The invite works once.
        await #expect(throws: (any Error).self) {
            _ = try await LinkPairing.join(code, role: "pocket", platform: "iOS", name: "Again")
        }

        let mac = try #require(RelayLinkStore(credentials: hostCredentials))
        let phone = try #require(RelayLinkStore(credentials: phoneCredentials))
        mac.start()
        phone.start()
        defer { mac.stop(); phone.stop() }
        #expect(await wait { mac.status == .online && phone.status == .online })
        #expect(await wait { phone.onlinePeers.contains { $0.role == "host" } && mac.onlinePeers.contains { $0.role == "pocket" } })

        // Phone → Mac.
        let sent = Date()
        phone.set(["id": "cmd-live", "text": "hi", "at": Date().timeIntervalSince1970, "typed": true], for: .command)
        #expect(await wait { (mac.dictionary(.command)?["id"] as? String) == "cmd-live" })
        let commandTime = Date().timeIntervalSince(sent)
        #expect(mac.dictionary(.command)?["text"] as? String == "hi")

        // Mac → phone.
        let replied = Date()
        mac.set(["id": "cmd-live", "state": "done", "text": "Hello!", "at": Date().timeIntervalSince1970], for: .reply)
        #expect(await wait { (phone.dictionary(.reply)?["text"] as? String) == "Hello!" })
        let replyTime = Date().timeIntervalSince(replied)

        // State, and clearing it.
        mac.set(#"{"petName":"Mochi"}"#, for: .look)
        #expect(await wait { phone.string(.look) == #"{"petName":"Mochi"}"# })
        mac.set(nil, for: .approval)

        // A message sent while the Mac is away waits for it.
        mac.stop()
        #expect(await wait { !phone.onlinePeers.contains { $0.role == "host" } })
        phone.set(["id": "cmd-queued", "text": "while away", "at": Date().timeIntervalSince1970], for: .command)
        try await Task.sleep(for: .milliseconds(500))
        let laterMac = try #require(RelayLinkStore(credentials: hostCredentials))
        laterMac.start()
        defer { laterMac.stop() }
        #expect(await wait { (laterMac.dictionary(.command)?["id"] as? String) == "cmd-queued" })
        #expect(laterMac.string(.look) == #"{"petName":"Mochi"}"#, "the Mac gets its own state back after a restart")
        print("live relay: command \(Int(commandTime * 1000)) ms, reply \(Int(replyTime * 1000)) ms")
        // Delete the throwaway room now, before the test run ends (the deferred delete covers a failed run).
        laterMac.stop()
        try await LinkPairing.deleteRoom(hostCredentials)
    }
}

@Suite("Mochi Link pushes")
struct LinkPushTests {
    private let card = PhoneSessionCard(id: "session-9", project: "secret-project", phase: "done",
                                        summary: TurnSummary(done: "Rotated the payroll keys.", next: []), files: ["payroll.swift"],
                                        finishedAt: 1_762_243_100, phaseSince: 1_762_243_000)

    @Test("A summary alert keeps its words, card and category; only category and thread stay readable")
    func alert() throws {
        let split = try #require(LinkPush.alert(from: PhoneAlertPayload.turnFinished(card)))
        #expect(split.inner["title"] as? String == "secret-project")
        #expect(split.inner["subtitle"] as? String == "Claude finished")
        #expect(split.inner["body"] as? String == "Rotated the payroll keys.")
        let userInfo = try #require(split.inner["userInfo"] as? [String: Any])
        #expect(userInfo["session"] as? String == "session-9")
        #expect(userInfo["card"] != nil && userInfo["aps"] == nil)
        #expect(split.category == PhoneAlertPayload.turnCategory && split.threadId == "session-9")
    }

    @Test("A Live Activity push hides the project and detail but still opens in the widget")
    func liveActivity() throws {
        let roomKey = LinkCrypto.newRoomKey()
        let laKey = LinkCrypto.liveActivityKey(from: roomKey)
        let state = LiveActivityState(phase: "working", title: "Claude is working", detail: "secret-project · 12 tools", since: 1_762_243_000, frame: 3)
        for payload in [LiveActivityPayload.update(state, timestamp: Date(), alert: true),
                        LiveActivityPayload.start(state, petName: "Mochi", companionName: "Patch", timestamp: Date())] {
            let apns = try #require(LinkPush.liveActivity(from: payload, liveActivityKey: laKey))
            let clear = String(decoding: try JSONSerialization.data(withJSONObject: apns), as: UTF8.self)
            #expect(!clear.contains("secret-project") && !clear.contains("12 tools"))
            let content = try #require(apns["content-state"] as? [String: Any])
            #expect(content["phase"] as? String == "working" && content["frame"] as? Int == 3)
            let sealed = try #require(content["sealed"] as? String)
            let opened = try #require(LinkPush.openLiveActivity(sealed, liveActivityKey: laKey))
            #expect(opened.title == "Claude is working" && opened.detail == "secret-project · 12 tools")
            // The room key itself can't open it, and neither can another room's.
            #expect(LinkPush.openLiveActivity(content["sealed"] as! String, liveActivityKey: roomKey) == nil)
            #expect(LinkPush.openLiveActivity(content["sealed"] as! String,
                                              liveActivityKey: LinkCrypto.liveActivityKey(from: LinkCrypto.newRoomKey())) == nil)
        }
    }
}

/// What the link compares to decide "changed" must encode the same way every time (JSONEncoder's default key order
/// isn't stable: unchanged state was resent every tick until the relay rate-limited the Mac).
struct StableJSONTests {
    @Test func linkStateEncodesTheSameEveryTime() {
        var settings = AppSettings()
        settings.room.items = [PlacedFurniture(kind: "plant", x: 0.2, y: 0.8), PlacedFurniture(kind: "lamp", x: 0.7, y: 0.6)]
        let look = PetLook(settings: settings, friendshipLevel: 3)
        #expect(Set((0..<100).map { _ in look.json }).count == 1)
        let sessions = PhoneSessions(enabled: true)
        #expect(Set((0..<100).map { _ in sessions.json }).count == 1)
    }
}
