import SwiftUI
import TamagotchiCore

struct PopoverView: View {
    let environment: AppEnvironment
    private var world: CompanionWorld { environment.world }

    var body: some View {
        VStack(spacing: 0) {
            SceneHeader(environment: environment)
                .frame(height: 178)
            VStack(alignment: .leading, spacing: 10) {
                ConnectionRow(environment: environment)
                if let missed = world.missed {
                    MissedEventsNotice(missed: missed) { world.dismissMissedNotice() }
                }
                SessionSection(environment: environment)
                if world.settings.showResultCards, let card = world.latestResult, Date().timeIntervalSince(card.completedAt) < 30 * 60 {
                    ResultCardView(card: card) { world.dismissResult(card.sessionID) }
                }
                RecentEvents(world: world)
                Divider().padding(.horizontal, -12)
                PetControls(environment: environment)
                FunRow(environment: environment)
            }
            .padding(12)
            Divider()
            Footer(environment: environment)
        }
        .frame(width: 360)
    }
}

// MARK: - Scene

private struct SceneHeader: View {
    let environment: AppEnvironment
    private var world: CompanionWorld { environment.world }

    var body: some View {
        // The popover is only open briefly, so it gets the smoothest motion.
        SceneView(world: world, style: .popover, visible: environment.ui.popoverVisible,
                  followsWindowVisibility: false, maxFrameRate: 60,
                  onPetTap: { world.interact(.pet) }, onCompanionTap: { world.pokeCompanion() })
            .overlay { RoomEditorOverlay(environment: environment) }
            .overlay(alignment: .bottom) {
                if let caption = world.activeCaption {
                    Text(caption.text)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
                        .padding(.bottom, 6)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .accessibilityLabel(caption.text)
                }
            }
            .overlay(alignment: .top) {
                if let toast = world.activeToast {
                    VStack(spacing: 1) {
                        Text(toast.title).font(.system(size: 11.5, weight: .bold, design: .rounded))
                        Text(toast.detail).font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.top, 8)
                    .padding(.horizontal, 30)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    if world.primarySession?.isSimulated == true || world.simulatorRunning {
                        Tag(text: "SIMULATED", color: .purple)
                    }
                    if world.settings.pauseReactions {
                        Tag(text: "PAUSED", color: .gray)
                    } else if NotificationPolicy.isQuiet(world.settings, at: Date()) {
                        Tag(text: "QUIET", color: .indigo)
                    }
                }
                .padding(8)
            }
            .animation(.spring(duration: 0.35), value: world.activeCaption?.text)
            .animation(.spring(duration: 0.35), value: world.activeToast?.title)
            .clipped()
    }
}

struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .heavy, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.85), in: Capsule())
    }
}

// MARK: - Connection

private struct ConnectionRow: View {
    let environment: AppEnvironment

    var body: some View {
        let connection = environment.world.connection
        HStack(spacing: 7) {
            Circle()
                .fill(color(connection.level))
                .frame(width: 7, height: 7)
            Text(connection.title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if connection.level == .setupNeeded || connection.level == .problem {
                Button("Set Up…") {
                    environment.windows.showSettings(tab: .claude)
                }
                .controlSize(.small)
            } else if let last = connection.lastEventAt {
                Text(last, style: .relative)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    func color(_ level: ConnectionStatus.Level) -> Color {
        switch level {
        case .good: return .green
        case .waiting: return .yellow
        case .setupNeeded: return .secondary
        case .problem: return .red
        }
    }
}

private struct MissedEventsNotice: View {
    let missed: TamagotchiCore.MissedEventsNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(missed.delivered) event\(missed.delivered == 1 ? "" : "s") arrived while MacTamagotchi wasn't listening")
                    .font(.system(size: 11, weight: .medium))
                Text(missed.dropped > 0
                     ? "They're in history (no reactions were played). \(missed.dropped) older or invalid event\(missed.dropped == 1 ? " was" : "s were") dropped, so some activity may be missing."
                     : "They're in history; no reactions were played for them.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Sessions

private struct SessionSection: View {
    let environment: AppEnvironment
    private var world: CompanionWorld { environment.world }

    var body: some View {
        let sessions = world.liveSessions
        if let primary = world.primarySession {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if sessions.count > 1 {
                        Menu {
                            Button {
                                world.pin(sessionID: nil)
                            } label: {
                                Label("Most relevant (automatic)", systemImage: world.settings.pinnedSessionID == nil ? "checkmark" : "")
                            }
                            Divider()
                            ForEach(sessions) { session in
                                Button {
                                    world.pin(sessionID: session.id)
                                } label: {
                                    Text("\(session.displayName) — \(session.statusLine(now: Date()))")
                                }
                            }
                        } label: {
                            Text(primary.displayName).font(.system(size: 12.5, weight: .semibold))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Text("\(sessions.count) sessions")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(primary.displayName).font(.system(size: 12.5, weight: .semibold))
                    }
                    if primary.isSimulated { Tag(text: "SIM", color: .purple) }
                    Spacer()
                    PhaseBadge(session: primary)
                }
                Text(primary.statusLine(now: Date()))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                if world.settings.pinnedSessionID != nil {
                    Text("Pinned — the menu bar follows this session")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(world.connection.isConnected ? "No Claude Code session right now" : "\(world.settings.petName) is keeping you company")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(world.connection.isConnected
                     ? "Start Claude Code in any project and \(world.settings.companionName) will join."
                     : "Connect Claude Code to meet \(world.settings.companionName), your coding companion.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PhaseBadge: View {
    let session: SessionSnapshot

    var body: some View {
        let (text, color) = label
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.13), in: Capsule())
    }

    var label: (String, Color) {
        if session.isStale(now: Date()) { return ("QUIET", .secondary) }
        switch session.phase {
        case .idle: return ("OPEN", .secondary)
        case .promptSubmitted, .thinking, .runningTool: return ("WORKING", .teal)
        case .waitingForUser: return ("NEEDS YOU", .orange)
        case .turnCompleted: return ("DONE", .green)
        case .turnFailed: return ("API ERROR", .red)
        case .ended: return ("ENDED", .secondary)
        }
    }
}

// MARK: - Result card

private struct ResultCardView: View {
    let card: ResultCard
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "flag.checkered")
                    .foregroundStyle(.green)
                Text("Turn complete · \(card.projectName)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(card.completedAt, style: .time)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss result")
            }
            Text(card.statusLine).font(.system(size: 11))
            if let outcome = card.buildTest {
                Label(outcome.summary, systemImage: outcome.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(outcome.passed ? .green : .red)
            } else {
                Text("No build or test result was received this turn.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            HStack {
                if let duration = card.observedTurnDuration {
                    Text("Observed turn length: \(Self.format(duration))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let path = card.projectPath, FileManager.default.fileExists(atPath: path) {
                    Button("Reveal Project") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    static func format(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "\(Int(duration))s"
    }
}

// MARK: - Timeline

struct EventRow: View {
    let event: CompanionEvent
    var showProject = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: EventStyle.symbol(for: event))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(EventStyle.color(for: event))
                .frame(width: 15)
            Text(event.summary)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            if showProject, let project = event.project?.displayName {
                Text(project).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if event.isSimulated { Tag(text: "SIM", color: .purple) }
            if event.delivery == .late { Tag(text: "LATE", color: .orange) }
            Text(event.timestamp, format: .dateTime.hour().minute().second())
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .opacity(event.delivery == .restored ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}

enum EventStyle {
    static func symbol(for event: CompanionEvent) -> String {
        switch event.kind {
        case .sessionStarted: return "play.circle"
        case .promptSubmitted: return "text.bubble"
        case .toolStarting:
            switch event.toolCategory {
            case .read?: return "doc.text"
            case .search?: return "magnifyingglass"
            case .edit?: return "pencil"
            case .shell?: return "terminal"
            case .web?: return "globe"
            case .agent?: return "person.2"
            case .plan?: return "checklist"
            case .ask?: return "questionmark.bubble"
            case .mcp?: return "puzzlepiece.extension"
            case .skill?: return "sparkles"
            default: return "wrench.and.screwdriver"
            }
        case .toolSucceeded: return event.buildTestOutcome != nil ? "checkmark.seal" : "checkmark.circle"
        case .toolFailed: return event.interrupted ? "stop.circle" : "exclamationmark.triangle"
        case .toolBatchFinished: return "square.stack.3d.up"
        case .permissionRequested, .attentionNeeded: return "hand.raised"
        case .permissionDenied: return "hand.raised.slash"
        case .notification: return "bell"
        case .subagentStarted, .subagentStopped: return "person.2.circle"
        case .turnCompleted: return "flag.checkered"
        case .turnFailed: return "exclamationmark.octagon"
        case .sessionEnded: return "stop.circle"
        case .report:
            switch event.report?.kind {
            case .milestone?: return "star"
            case .commit?: return "arrow.triangle.branch"
            default: return event.report?.status == .failed ? "xmark.seal" : "checkmark.seal"
            }
        case .unknown: return "questionmark.circle"
        }
    }

    static func color(for event: CompanionEvent) -> Color {
        switch event.kind {
        case .toolFailed: return event.interrupted ? .secondary : .orange
        case .permissionRequested, .attentionNeeded: return .orange
        case .turnCompleted: return .green
        case .turnFailed: return .red
        case .report: return event.report?.status == .failed ? .red : .green
        case .toolSucceeded: return event.buildTestOutcome != nil ? .green : .secondary
        default: return .secondary
        }
    }
}

private struct RecentEvents: View {
    let world: CompanionWorld

    var body: some View {
        let sessionID = world.primarySession?.id
        let events = world.timeline.reversed().filter { sessionID == nil || $0.sessionID == sessionID || $0.sessionID == nil }.prefix(5)
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("RECENT")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.6)
                ForEach(Array(events)) { event in
                    EventRow(event: event)
                }
            }
        }
    }
}

// MARK: - Controls

private struct PetControls: View {
    let environment: AppEnvironment
    private var world: CompanionWorld { environment.world }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ControlButton(title: "Pet", symbol: "hand.wave") { world.interact(.pet) }
                ControlButton(title: "Play", symbol: "circle.circle") { world.interact(.play) }
                ControlButton(title: "Treat", symbol: "birthday.cake") { world.interact(.treat) }
                ControlButton(title: "Milestone", symbol: "star") { world.markMilestone(label: nil) }
                    .help("Mark a milestone you reached — celebrates and is recorded in history")
            }
            HStack(spacing: 6) {
                ToggleChip(title: "Sound", on: world.settings.soundEnabled, symbolOn: "speaker.wave.2.fill", symbolOff: "speaker.slash") {
                    world.settings.soundEnabled.toggle()
                }
                ToggleChip(title: "Quiet", on: world.settings.quietMode, symbolOn: "moon.fill", symbolOff: "moon") {
                    world.settings.quietMode.toggle()
                }
                ToggleChip(title: "Pause", on: world.settings.pauseReactions, symbolOn: "pause.circle.fill", symbolOff: "pause.circle") {
                    world.settings.pauseReactions.toggle()
                }
                ToggleChip(title: "Desktop", on: world.settings.desktopPetEnabled, symbolOn: "macwindow.on.rectangle", symbolOff: "macwindow") {
                    environment.toggleDesktopPet()
                }
            }
            friendship
        }
    }

    private var friendship: some View {
        let progress = world.progress
        return HStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: index < progress.friendshipLevel ? "heart.fill" : "heart")
                    .font(.system(size: 9))
                    .foregroundStyle(index < progress.friendshipLevel ? Color.pink : Color.secondary.opacity(0.5))
            }
            Text("Friendship level \(progress.friendshipLevel)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            if let next = progress.pointsToNextLevel {
                Text("\(next) to next")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ControlButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 13))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChipButtonStyle(highlighted: false))
        .accessibilityLabel(title)
    }
}

private struct ToggleChip: View {
    let title: String
    let on: Bool
    let symbolOn: String
    let symbolOff: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: on ? symbolOn : symbolOff).font(.system(size: 10.5))
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChipButtonStyle(highlighted: on))
        .accessibilityLabel(title)
        .accessibilityValue(on ? "On" : "Off")
    }
}

struct ChipButtonStyle: ButtonStyle {
    var highlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(highlighted ? Color.accentColor.opacity(0.14) : Color.primary.opacity(configuration.isPressed ? 0.12 : 0.055))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - Footer

private struct Footer: View {
    let environment: AppEnvironment

    var body: some View {
        HStack(spacing: 14) {
            Button("Activity") { environment.windows.showActivity() }
            Button("Settings") { environment.windows.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
