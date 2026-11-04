import Darwin
import Foundation
import Testing
@testable import TamagotchiCore
import TamagotchiWire

/// Collects events delivered by the bridge on its queue.
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [WireEvent] = []
    private var states: [LocalEventBridge.State] = []

    func add(_ event: WireEvent) { lock.withLock { events.append(event) } }
    func add(_ state: LocalEventBridge.State) { lock.withLock { states.append(state) } }
    var received: [WireEvent] { lock.withLock { events } }
    var lastState: LocalEventBridge.State? { lock.withLock { states.last } }
}

func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// Short socket paths: sun_path is only 104 bytes.
func shortSocketURL() -> URL {
    let directory = URL(fileURLWithPath: "/tmp/mtg-\(getpid())-\(UInt32.random(in: 0...UInt32.max))", isDirectory: true)
    return directory.appendingPathComponent("b.sock")
}

@Suite("Local event bridge", .serialized)
struct BridgeTests {
    func startBridge(_ socket: URL, health: TimeInterval = 5) async -> (LocalEventBridge, Inbox) {
        let bridge = LocalEventBridge(socketURL: socket, readTimeout: 0.5, healthInterval: health)
        let inbox = Inbox()
        bridge.start(deliver: { inbox.add($0) }, stateChanged: { state, _ in inbox.add(state) })
        _ = await waitUntil { inbox.lastState?.isListening == true }
        return (bridge, inbox)
    }

    @Test func deliversValidatedEvents() async throws {
        let socket = shortSocketURL()
        let (bridge, inbox) = await startBridge(socket)
        defer { bridge.stop() }
        let outcome = BridgeClient.send(try TestSupport.wire("PreToolUse", tool: "Read").encodedLine(), to: socket)
        #expect(outcome == .accepted)
        #expect(await waitUntil { inbox.received.count == 1 })
        #expect(inbox.received.first?.tool == "Read")
        // The socket file is private to the user.
        var info = stat()
        stat(socket.path, &info)
        #expect(info.st_mode & 0o077 == 0)
    }

    @Test func rejectsMalformedAndOversizedData() async throws {
        let socket = shortSocketURL()
        let (bridge, inbox) = await startBridge(socket)
        defer { bridge.stop() }
        #expect(BridgeClient.send(Data("{not json}\n".utf8), to: socket) == .rejected("malformed"))
        var huge = Data(repeating: 0x20, count: EventSchemaValidator.maxLineBytes + 100)
        huge.append(0x0A)
        let outcome = BridgeClient.send(huge, to: socket, timeout: 2)
        if case .accepted = outcome { Issue.record("oversized event accepted") }
        let (_, stats) = bridge.currentState()
        #expect(stats.rejected >= 2)
        #expect(inbox.received.isEmpty)
    }

    @Test func reportsUnavailableWhenNotRunning() throws {
        let socket = shortSocketURL()
        if case .unavailable = BridgeClient.send(try TestSupport.wire("Stop").encodedLine(), to: socket) {} else {
            Issue.record("expected unavailable")
        }
    }

    @Test func replacesStaleSocketFiles() async throws {
        let socket = shortSocketURL()
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: socket.path, contents: Data("stale".utf8))
        let (bridge, _) = await startBridge(socket)
        defer { bridge.stop() }
        #expect(bridge.currentState().0.isListening)
        #expect(BridgeClient.send(try TestSupport.wire("Stop").encodedLine(), to: socket) == .accepted)
    }

    @Test func refusesToStealALiveSocket() async throws {
        let socket = shortSocketURL()
        let (first, _) = await startBridge(socket)
        defer { first.stop() }
        let (second, inbox) = await startBridge(socket)
        _ = await waitUntil { inbox.lastState != nil }
        if case .failed = second.currentState().0 {} else { Issue.record("second bridge should not take over") }
        #expect(first.currentState().0.isListening)
    }

    @Test func recoversWhenTheSocketFileIsDeleted() async throws {
        let socket = shortSocketURL()
        let (bridge, _) = await startBridge(socket, health: 0.3)
        defer { bridge.stop() }
        unlink(socket.path)
        if case .unavailable = BridgeClient.send(try TestSupport.wire("Stop").encodedLine(), to: socket) {} else {
            Issue.record("expected the deleted socket to be unreachable")
        }
        #expect(await waitUntil(timeout: 3) { FileManager.default.fileExists(atPath: socket.path) })
        #expect(BridgeClient.send(try TestSupport.wire("Stop").encodedLine(), to: socket) == .accepted)
        #expect(bridge.currentState().1.restarts >= 1)
    }

    @Test func handlesSlowClientsWithoutBlocking() async throws {
        let socket = shortSocketURL()
        let (bridge, _) = await startBridge(socket)
        defer { bridge.stop() }
        // A client that connects and sends nothing must not block others.
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = BridgeClient.makeAddress(socket.path)!
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(BridgeClient.send(try TestSupport.wire("Stop").encodedLine(), to: socket) == .accepted)
        close(fd)
    }
}

@Suite("Spool")
struct SpoolTests {
    @Test func appendsAndDrains() throws {
        let url = TestSupport.temporaryDirectory().appendingPathComponent("spool/pending.jsonl")
        for index in 0..<3 {
            #expect(EventSpool.append(try TestSupport.wire("Stop", id: "e\(index)").encodedLine(), to: url))
        }
        let drained = EventSpool.drain(url)
        #expect(drained.lines.count == 3)
        #expect(drained.droppedCount == 0)
        #expect(EventSpool.drain(url).lines.isEmpty)
    }

    @Test func staysBoundedAndCountsDrops() throws {
        let url = TestSupport.temporaryDirectory().appendingPathComponent("spool/pending.jsonl")
        let line = try TestSupport.wire("PreToolUse", tool: "Read").encodedLine()
        for _ in 0..<400 { EventSpool.append(line, to: url, maxBytes: 16 * 1024) }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        #expect(size <= 16 * 1024)
        let drained = EventSpool.drain(url)
        #expect(drained.droppedCount > 0)
        #expect(drained.lines.count + drained.droppedCount == 400)
    }

    @Test @MainActor func providerDeliversSpooledEventsAsLate() throws {
        let home = URL(fileURLWithPath: "/tmp/mtg-home-\(UInt32.random(in: 0...UInt32.max))", isDirectory: true)
        let paths = BridgePaths(home: home)
        EventSpool.append(try TestSupport.wire("Stop").encodedLine(), to: paths.spoolFile)
        EventSpool.append(Data("{\"garbage\": true}\n".utf8), to: paths.spoolFile)
        let provider = ClaudeHookEventProvider(paths: paths)
        var delivered: [(WireEvent, EventDelivery)] = []
        provider.start { wire, delivery in delivered.append((wire, delivery)) }
        defer { provider.stop() }
        #expect(delivered.count == 1)
        #expect(delivered.first?.1 == .late)
    }
}
