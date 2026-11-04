import AppKit
import SwiftUI
import TamagotchiCore
import TamagotchiWire

/// Guided, consent-first Claude Code connection.
struct ClaudeSettings: View {
    let environment: AppEnvironment
    @State private var confirmConnect = false
    @State private var confirmDisconnect = false
    @State private var previewText: String?
    @State private var showPreview = false

    private var integration: IntegrationController { environment.integration }
    private var world: CompanionWorld { environment.world }

    var body: some View {
        Form {
            statusSection
            connectionSection
            eventsSection
            reportsSection
            troubleshootingSection
        }
        .formStyle(.grouped)
        .task { await integration.refresh() }
        .confirmationDialog("Connect Claude Code?", isPresented: $confirmConnect) {
            Button("Back Up and Connect") { Task { await integration.connect() } }
        } message: {
            Text("MacTamagotchi will back up \(integration.settingsFile.path) and add \(integration.events.count) hook entries. Your existing settings and hooks are kept exactly as they are.")
        }
        .confirmationDialog("Disconnect Claude Code?", isPresented: $confirmDisconnect) {
            Button("Back Up and Disconnect", role: .destructive) { Task { await integration.disconnect() } }
        } message: {
            Text("Only MacTamagotchi's own hook entries are removed. Everything else in your settings stays.")
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Claude Code") {
                if let installation = integration.installation {
                    Text("\(installation.version ?? "unknown version") · \(installation.executable.path)")
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                } else if integration.searched {
                    Text("Not found — MacTamagotchi works without it").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            LabeledContent("Connection") {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(world.connection.title)
                }
            }
            LabeledContent("Event bridge") {
                Text(world.connection.bridgeListening ? "Listening on a private socket" : (world.connection.bridgeError ?? "Starting…"))
                    .foregroundStyle(.secondary)
            }
            if let last = world.connection.lastEventAt {
                LabeledContent("Last real event") { Text(last, style: .relative).foregroundStyle(.secondary) }
            }
        }
    }

    private var color: Color {
        switch world.connection.level {
        case .good: return .green
        case .waiting: return .yellow
        case .setupNeeded: return .secondary
        case .problem: return .red
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            Text("MacTamagotchi uses Claude Code's documented **hooks**. Each hook runs a tiny helper that forwards a sanitized summary of the event to this app over a private local socket, then exits successfully within milliseconds — it never blocks Claude, never prints into your session and never changes what Claude does.")
                .font(.callout)
            Text("Settings file: \(integration.settingsFile.path). A timestamped backup is written before every change, and existing hooks are merged, never replaced.")
                .font(.caption).foregroundStyle(.secondary)
            if let inspection = integration.inspection {
                if inspection.otherHookCount > 0 {
                    Label("\(inspection.otherHookCount) existing hook\(inspection.otherHookCount == 1 ? "" : "s") from you or other tools will be preserved.", systemImage: "checkmark.shield")
                        .font(.caption)
                }
                if inspection.hooksDisabled {
                    Label("Your settings contain \"disableAllHooks\": true, so Claude Code won't run any hooks until you change it.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if inspection.managedHooksOnly {
                    Label("Managed settings only allow hooks from your organization; ask your administrator.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if case .unreadable(let reason) = inspection.status {
                    Label(reason, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                }
            }
            HStack {
                if integration.isInstalled {
                    Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
                    Button("Test Connection") { Task { await integration.testConnection() } }
                } else {
                    Button(integration.hasAnyInstall ? "Update Connection…" : "Connect Claude Code…") { confirmConnect = true }
                        .buttonStyle(.borderedProminent)
                    if integration.hasAnyInstall {
                        Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
                    }
                }
                Spacer()
                Button(showPreview ? "Hide Changes" : "Preview Changes") {
                    previewText = integration.preview()
                    showPreview.toggle()
                }
                if integration.busy { ProgressView().controlSize(.small) }
            }
            .disabled(integration.busy)
            if let message = integration.lastMessage {
                Label(message, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            }
            if let error = integration.lastError {
                Label(error, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let ping = integration.pingResult {
                Label(ping, systemImage: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(.secondary)
            }
            if showPreview {
                ScrollView {
                    Text(previewText ?? "Could not compute the change (see errors above).")
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var eventsSection: some View {
        Section("Events") {
            if let report = integration.compatibility {
                Text(report.method == "inspected"
                     ? "Detected by inspecting the installed Claude Code\(report.claudeVersion.map { " \($0)" } ?? "")."
                     : "Claude Code could not be inspected, so only long-established events are used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ClaudeHookEvent.allCases) { event in
                let supported = integration.events.contains(event)
                HStack {
                    Image(systemName: supported ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(supported ? Color.green : Color.secondary)
                    Text(event.rawValue).font(.system(size: 12, weight: .medium, design: .monospaced))
                    Text(event.purpose).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !supported { Text("not available").font(.caption).foregroundStyle(.tertiary) }
                }
            }
        }
    }

    private var reportsSection: some View {
        Section("Explicit build & test results") {
            Text("A finished turn says nothing about builds or tests. To celebrate real results, report them from your own scripts:")
                .font(.callout)
            let helper = environment.paths.installedHelper.path
            CommandSnippet(text: "swift test && '\(helper)' report test passed || '\(helper)' report test failed")
            CommandSnippet(text: "'\(helper)' report build passed --label \"Xcode\"")
            CommandSnippet(text: "'\(helper)' report milestone reached --label \"Shipped v1\"")
            Toggle("Also recognise build/test commands Claude runs (only when the exit status is trustworthy)", isOn: Binding(
                get: { environment.settingsStore.settings.celebrateCommandResults },
                set: { environment.settingsStore.settings.celebrateCommandResults = $0 }
            ))
            Text("Piped commands, `|| true`, trailing `;` commands and background runs are never treated as passing.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var troubleshootingSection: some View {
        Section("Troubleshooting") {
            VStack(alignment: .leading, spacing: 4) {
                Text("• Hooks are read when a Claude Code session starts: restart sessions that were open before connecting.")
                Text("• Type /hooks inside Claude Code to see the installed entries (they run mactamagotchi-hook).")
                Text("• If MacTamagotchi isn't running, events are kept in a small spool and shown as “late” next time.")
                Text("• The helper always exits 0 and prints nothing, even if this app was deleted.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            LabeledContent("Bridge statistics") {
                Text("accepted \(world.connection.eventsAccepted) · rejected \(world.connection.eventsRejected) · refused peers \(world.connection.refusedPeers)")
                    .foregroundStyle(.secondary)
            }
            if let rejection = world.connection.lastRejection {
                LabeledContent("Last rejection") { Text(rejection).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Reveal Settings File") {
                    NSWorkspace.shared.activateFileViewerSelecting([integration.settingsFile])
                }
                Button("Show Backups") {
                    BridgePaths.ensurePrivateDirectory(environment.paths.backupsDirectory)
                    NSWorkspace.shared.activateFileViewerSelecting([environment.paths.backupsDirectory])
                }
                Button("Copy Diagnostics") { copyDiagnostics() }
                Spacer()
                Button("Re-check") { Task { await integration.refresh() } }
            }
        }
    }

    private func copyDiagnostics() {
        let connection = world.connection
        var lines = [
            "MacTamagotchi diagnostics",
            "Claude Code: \(integration.installation?.version ?? "not found")",
            "Events supported: \(integration.events.map(\.rawValue).joined(separator: ", "))",
            "Integration: \(connection.integration)",
            "Bridge listening: \(connection.bridgeListening) \(connection.bridgeError ?? "")",
            "Accepted \(connection.eventsAccepted), rejected \(connection.eventsRejected), refused peers \(connection.refusedPeers)",
            "Last rejection: \(connection.lastRejection ?? "none")",
            "Duplicates ignored: \(world.diagnostics.duplicatesIgnored), unknown events: \(world.diagnostics.unknownEvents), late: \(world.diagnostics.lateEvents)",
            "Sessions: \(world.sessions.count)",
            "Helper: \(FileManager.default.isExecutableFile(atPath: environment.paths.installedHelper.path) ? "installed" : "missing")",
        ]
        if let ping = integration.pingResult { lines.append("Ping: \(ping)") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

private struct CommandSnippet: View {
    let text: String

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Development-only tools. Everything here is clearly simulated.
struct DeveloperSettings: View {
    let environment: AppEnvironment
    @State private var petAnimation: PetAnimation = .dance
    @State private var companionAnimation: CompanionAnimation = .celebrate
    @State private var interaction: InteractionID = .coffeeDelivery

    private var simulator: EventSimulator { environment.simulator }
    private var world: CompanionWorld { environment.world }

    var body: some View {
        Form {
            Section("Event simulator") {
                Label("Simulated events are tagged SIM, use demo session ids, are never written to history, never count toward achievements and never post notifications.", systemImage: "theatermasks")
                    .font(.caption)
                    .foregroundStyle(.purple)
                ForEach(EventSimulator.Scenario.allCases) { scenario in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(scenario.title).font(.system(size: 12, weight: .medium))
                            Text(scenario.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Run") {
                            simulator.run(scenario)
                            environment.statusItem.showPopover()
                        }
                    }
                }
                HStack {
                    Button("Stop") { simulator.stop() }
                    Button("Clear Simulated Sessions") { world.clearSimulated() }
                }
            }
            Section("Single simulated events") {
                let columns = [GridItem(.adaptive(minimum: 150), spacing: 6)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    eventButton("SessionStart")
                    eventButton("UserPromptSubmit")
                    eventButton("PreToolUse", tool: "Read")
                    eventButton("PreToolUse", tool: "Grep")
                    eventButton("PreToolUse", tool: "Edit")
                    eventButton("PreToolUse", tool: "Bash")
                    eventButton("PreToolUse", tool: "WebFetch")
                    eventButton("PostToolUse", tool: "Bash")
                    eventButton("PostToolUseFailure", tool: "Bash")
                    eventButton("PermissionRequest", tool: "Bash")
                    eventButton("Notification", label: "Notification (idle)", notification: "idle_prompt")
                    eventButton("Stop")
                    eventButton("StopFailure", reason: "rate_limit")
                    eventButton("SessionEnd", reason: "prompt_input_exit")
                }
            }
            Section("Animation preview") {
                HStack {
                    Picker("Pet", selection: $petAnimation) {
                        ForEach(PetAnimation.allCases.filter { !$0.isLoop && $0 != .scripted }, id: \.self) { Text($0.title).tag($0) }
                    }
                    Button("Play") { world.preview(pet: petAnimation) }
                }
                HStack {
                    Picker("Companion", selection: $companionAnimation) {
                        ForEach(CompanionAnimation.allCases.filter { !$0.isLoop && $0 != .scripted }, id: \.self) { Text($0.title).tag($0) }
                    }
                    Button("Play") { world.preview(companion: companionAnimation) }
                        .disabled(!world.companionPresent)
                }
                HStack {
                    Picker("Interaction", selection: $interaction) {
                        ForEach(InteractionID.allCases) { Text($0.title).tag($0) }
                    }
                    Button("Play") { world.startInteraction(interaction, priority: .critical, variant: Int.random(in: 0..<100)) }
                        .disabled(!world.companionPresent)
                }
                Text(world.companionPresent ? "Open the popover to watch." : "The companion appears during sessions — run a scenario first, or set Characters › Show companion › Always.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                let d = world.diagnostics
                Text("Duplicates ignored \(d.duplicatesIgnored) · unknown events \(d.unknownEvents)\(d.lastUnknownName.map { " (last: \($0))" } ?? "") · late \(d.lateEvents) · simulated \(d.simulatedEvents)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func eventButton(_ name: String, tool: String? = nil, label: String? = nil, notification: String? = nil, reason: String? = nil) -> some View {
        Button(label ?? (tool.map { "\(name) · \($0)" } ?? name)) {
            simulator.send(name, tool: tool, notificationType: notification, reason: reason)
        }
        .controlSize(.small)
    }
}
