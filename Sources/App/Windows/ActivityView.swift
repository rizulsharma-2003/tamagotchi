import SwiftUI
import TamagotchiCore

/// The full activity view: sessions on the left, a session's details and its
/// event history on the right. Sessions are always shown separately.
struct ActivityView: View {
    let environment: AppEnvironment
    @State private var selection: String? = ActivityView.allEvents
    @State private var hideToolActivity = false
    @State private var confirmClear = false

    static let allEvents = "__all__"
    private var world: CompanionWorld { environment.world }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("All events", systemImage: "list.bullet").tag(ActivityView.allEvents)
                Section("Sessions") {
                    ForEach(world.sessions) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(session.displayName).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                if session.isSimulated { Tag(text: "SIM", color: .purple) }
                            }
                            Text(session.statusLine(now: Date())).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(session.id)
                    }
                    if world.sessions.isEmpty {
                        Text("No sessions yet").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            VStack(spacing: 0) {
                if let id = selection, id != ActivityView.allEvents, let session = world.sessions.first(where: { $0.id == id }) {
                    SessionDetail(session: session, world: world)
                    Divider()
                }
                eventList
                Divider()
                footer
            }
        }
        .confirmationDialog("Clear all stored history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                world.clearHistory()
                environment.focus.log.clear()
            }
        } message: {
            Text("This deletes the local event journal. Current sessions keep running.")
        }
    }

    private var events: [CompanionEvent] {
        var events = world.timeline.reversed() as [CompanionEvent]
        if let id = selection, id != ActivityView.allEvents {
            events = environment.journal.recent(500, session: id).reversed()
            let simulated = world.timeline.filter { $0.sessionID == id && $0.isSimulated }.reversed()
            if events.isEmpty { events = Array(simulated) }
        } else {
            let stored = environment.journal.recent(500)
            let simulated = world.timeline.filter(\.isSimulated)
            events = (stored + simulated).sorted { $0.timestamp > $1.timestamp }
        }
        if hideToolActivity {
            events.removeAll { [.toolStarting, .toolSucceeded, .toolBatchFinished].contains($0.kind) }
        }
        return events
    }

    private var eventList: some View {
        List(events) { event in
            EventRow(event: event, showProject: selection == ActivityView.allEvents)
                .help(details(event))
        }
        .listStyle(.inset)
        .overlay {
            if events.isEmpty {
                ContentUnavailableView("No events", systemImage: "tray",
                                       description: Text("Real Claude Code events appear here once the integration is connected."))
            }
        }
        .toolbar {
            Toggle(isOn: $hideToolActivity) {
                Label("Hide tool activity", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }

    private func details(_ event: CompanionEvent) -> String {
        var lines = ["\(event.rawName) · \(event.origin.rawValue) · \(event.delivery.rawValue) · confidence: \(event.confidence.rawValue)"]
        if let tool = event.toolName { lines.append("Tool: \(tool)") }
        for (key, value) in event.metadata.sorted(by: { $0.key < $1.key }) where key != "agentId" {
            lines.append("\(key): \(value)")
        }
        return lines.joined(separator: "\n")
    }

    private var footer: some View {
        let connection = world.connection
        let diagnostics = world.diagnostics
        return HStack(spacing: 14) {
            Label(connection.title, systemImage: connection.isConnected ? "dot.radiowaves.left.and.right" : "bolt.horizontal.circle")
                .lineLimit(1)
            Text("Since launch: received \(connection.eventsAccepted) · rejected \(connection.eventsRejected) · duplicates \(diagnostics.duplicatesIgnored) · late \(diagnostics.lateEvents)")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear History…") { confirmClear = true }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct SessionDetail: View {
    let session: SessionSnapshot
    let world: CompanionWorld

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.displayName).font(.system(size: 17, weight: .bold, design: .rounded))
                PhaseBadge(session: session)
                Spacer()
                if world.settings.pinnedSessionID == session.id {
                    Button("Unpin") { world.pin(sessionID: nil) }
                } else {
                    Button("Pin to Menu Bar") { world.pin(sessionID: session.id) }
                }
                if let path = session.project?.path, FileManager.default.fileExists(atPath: path) {
                    Button("Reveal Project") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
            }
            Text(session.statusLine(now: Date())).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    fact("First seen", session.firstSeen.formatted(date: .omitted, time: .standard))
                    fact("Last event", session.lastEventAt.formatted(date: .omitted, time: .standard))
                    fact("Turns completed", "\(session.turnsCompleted)")
                }
                GridRow {
                    fact("Tool calls this turn", "\(session.toolCallsThisTurn)")
                    fact("Tool errors this turn", "\(session.failuresThisTurn)")
                    fact("Subagents running", "\(session.activeSubagents.count)")
                }
                GridRow {
                    fact("Start observed", session.startObserved ? "Yes" : "No (joined mid-session)")
                    fact("Late events", "\(session.lateEvents)")
                    fact("Build/test result", session.lastBuildTest?.summary ?? "None received")
                }
            }
            .font(.system(size: 11))
            Text("Counts are observed events only — they describe activity, not the quality of the work.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            Text(value).lineLimit(1)
        }
    }
}
