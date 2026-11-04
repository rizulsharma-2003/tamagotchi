import SwiftUI
import TamagotchiCore

struct ContentView: View {
    let coordinator: ActivityCoordinator
    let link: MacLink
    @State private var phone = PhoneWorld.shared
    @State private var talk: TalkModel
    @State private var typing = false
    @State private var typed = ""
    @State private var showSettings = false
    @State private var showUpdates = false
    @State private var updates = UpdatesStore.shared
    @State private var reader = UpdatesReader.shared
    @State private var drafting: AgentNote?
    @FocusState private var fieldFocused: Bool

    init(coordinator: ActivityCoordinator, link: MacLink) {
        self.coordinator = coordinator
        self.link = link
        _talk = State(initialValue: TalkModel(link: link))
    }

    var body: some View {
        ZStack {
            PocketBackground()
            ScrollView {
                VStack(spacing: 14) {
                    header
                    room
                    actions
                    if typing { typingField }
                    if let approval = link.approval { ApprovalCard(approval: approval, link: link) }
                    if let agent = link.agent, agent.enabled {
                        let waiting = updates.waiting(in: agent)
                        AgentCard(pending: agent, waiting: waiting, petName: phone.world.settings.petName,
                                  checking: checkingForUpdates, speaking: reader.speaking,
                                  historyCount: updates.entries.count - agent.items.count,
                                  cloudAskedAt: link.cloudAskedAt, cloudAvailable: link.cloudAvailable,
                                  cloudSeen: link.cloudSeenAt != nil, checkedBy: link.lastCheckedBy, cloudError: link.cloudError,
                                  canDraft: link.draftsAvailable,
                                  speak: { reader.toggle(waiting) }, open: { showUpdates = true }, checkNow: checkForUpdates,
                                  markDone: { note in withAnimation(.snappy) { updates.toggleDone(note.id) } },
                                  draft: { drafting = $0 })
                    }
                    claude
                    if !link.exchanges.isEmpty { recent }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .scrollDisabled(talk.isHolding)
        }
        .tint(MochiStyle.accent)
        .sheet(isPresented: $showSettings) { PocketSettingsView(coordinator: coordinator, link: link, phone: phone) }
        .sheet(isPresented: $showUpdates) {
            UpdatesView(link: link, petName: phone.world.settings.petName, checking: checkingForUpdates, checkNow: checkForUpdates)
        }
        .sheet(item: $drafting) { DraftReplySheet(note: $0, link: link) }
        .onChange(of: link.exchanges) { _, _ in talk.linkChanged() }
        .onChange(of: link.cloudAskedAt) { _, _ in talk.cloudTookOver() }
        .task {
            if let text = UserDefaults.standard.string(forKey: "sendCommand") { talk.send(typed: text) }
        }
    }

    // MARK: Updates

    private var checkingForUpdates: Bool { talk.isBusy || link.cloudChecking }

    /// "Check now": straight to Mochi Cloud when that's on and set up, otherwise the Mac first.
    private func checkForUpdates() {
        if link.checkNowUsesCloud, link.cloudAvailable {
            talk.cloudChecking()
            link.checkInCloud()
        } else {
            talk.send(typed: "What's pending?")
            // A Mac that's off or offline can't answer: Mochi Cloud can.
            if let id = link.exchanges.last?.id { link.askCloudIfMacSilent(for: id) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(phone.world.settings.petName).font(.system(size: 32, weight: .heavy, design: .rounded))
                Text("and \(phone.world.settings.companionName), from your Mac")
                    .font(.system(.subheadline, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 17, weight: .semibold))
                        .padding(9).background(Circle().fill(.white.opacity(0.85)))
                }
                .foregroundStyle(.secondary)
                .accessibilityLabel("Settings")
                if phone.friendshipLevel > 0 {
                    Label("Level \(phone.friendshipLevel)", systemImage: "heart.fill")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color(red: 0.93, green: 0.36, blue: 0.45))
                }
                let linked = phone.linkedToMac || (coordinator.iCloudAvailable && coordinator.hasPushToStartToken)
                Label(linked ? "Mac linked" : "Not linked", systemImage: linked ? "checkmark.icloud.fill" : "icloud.slash")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(linked ? Color.green : Color.secondary)
            }
        }
        .padding(.top, 6)
    }

    // MARK: Room

    private var room: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                RoomView(phone: phone, talk: talk)
                    .frame(height: 290)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                if let text = bubbleText {
                    SpeechBubble(text: text, highlighted: talk.isHolding)
                        .padding(.horizontal, 22)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
                if talk.isBusy, !talk.isHolding {
                    HStack {
                        Spacer()
                        Button { talk.cancel() } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                                .padding(8).background(Circle().fill(.white.opacity(0.9)))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .offset(y: 230)
                }
            }
            .animation(.spring(duration: 0.3), value: bubbleText)
            Text(talk.isHolding ? "Listening… let go to send" : "Tap \(phone.world.settings.petName) to pet · press and hold to talk")
                .font(.system(.footnote, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var bubbleText: String? {
        talk.bubble ?? phone.world.activeSpeech?.text
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 10) {
            ActionButton(title: "Pet", symbol: "heart.fill", tint: Color(red: 0.93, green: 0.40, blue: 0.48)) { phone.interact(.pet) }
            ActionButton(title: "Play", symbol: "tennisball.fill", tint: Color(red: 0.36, green: 0.72, blue: 0.45)) { phone.interact(.play) }
            ActionButton(title: "Treat", symbol: "birthday.cake.fill", tint: Color(red: 0.95, green: 0.62, blue: 0.25)) { phone.interact(.treat) }
            ActionButton(title: "Type", symbol: "keyboard", tint: MochiStyle.accent) {
                typing.toggle()
                fieldFocused = typing
            }
        }
    }

    private var typingField: some View {
        HStack {
            TextField("Tell \(phone.world.settings.petName) what to do on your Mac", text: $typed)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit(sendTyped)
            Button("Send", action: sendTyped).fontWeight(.semibold).disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.9)))
    }

    private func sendTyped() {
        talk.send(typed: typed)
        typed = ""
        typing = false
        fieldFocused = false
    }

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recently").font(.system(.headline, design: .rounded))
            ForEach(link.exchanges.suffix(3).reversed()) { exchange in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: exchange.state)).foregroundStyle(color(for: exchange.state)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        if let project = exchange.project {
                            Text("To Claude in \(project)").font(.system(.caption, design: .rounded).weight(.semibold)).foregroundStyle(.secondary)
                        }
                        Text(exchange.text).font(.system(.subheadline, design: .rounded).weight(.medium)).lineLimit(2)
                        Text(exchange.reply ?? status(for: exchange.state))
                            .font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(0.75)))
    }

    private func icon(for state: MacLink.State) -> String {
        switch state {
        case .sending: return "paperplane"
        case .working: return "gearshape.2"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private func color(for state: MacLink.State) -> Color {
        switch state {
        case .done: return .green
        case .failed: return .orange
        default: return MochiStyle.accent
        }
    }

    private func status(for state: MacLink.State) -> String {
        switch state {
        case .sending: return "Sending to your Mac…"
        case .working: return "Your Mac is on it…"
        case .done: return "Done"
        case .failed: return "Didn't work"
        }
    }

    // MARK: Claude on your Mac

    private var claude: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Claude on your Mac").font(.system(.headline, design: .rounded))
                Spacer()
                if !link.sessions.isEmpty {
                    Text("\(link.sessions.count) session\(link.sessions.count == 1 ? "" : "s")")
                        .font(.system(.caption, design: .rounded).weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            if link.summariesShared != true {
                Label {
                    Text(link.summariesShared == false
                         ? "Turn on “Send Claude's summaries to my iPhone” in \(phone.world.settings.petName)'s Settings › iPhone on your Mac to see what each session did and reply to it here."
                         : "Waiting to hear from your Mac…")
                } icon: {
                    Image(systemName: "text.bubble")
                }
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(0.75)))
            } else if link.sessions.isEmpty {
                Text("No Claude sessions right now.")
                    .font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(0.75)))
            } else {
                ForEach(link.sessions) { card in
                    SessionCard(card: card) { text in talk.send(typed: text, project: card.project, session: card.id) }
                }
            }
        }
    }
}

/// A big rounded action under the room.
struct ActionButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                Text(title).font(.system(.caption, design: .rounded).weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.85)))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

/// Mochi's speech bubble above the avatar.
struct SpeechBubble: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text)
            .font(.system(.body, design: .rounded).weight(.medium))
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(highlighted ? MochiStyle.accent.opacity(0.18) : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(highlighted ? MochiStyle.accent : Color.black.opacity(0.06), lineWidth: highlighted ? 2 : 1))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
            .id(text)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
    }
}

/// A message your Mac wants to send to one of your Claude sessions, waiting for your OK.
struct ApprovalCard: View {
    let approval: MacLink.Approval
    let link: MacLink

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "paperplane.fill").foregroundStyle(MochiStyle.accent)
                Text("Send to Claude").font(.system(.headline, design: .rounded))
                Text(approval.project ?? approval.target).font(.system(.subheadline, design: .rounded)).foregroundStyle(.secondary)
            }
            Text(approval.message)
                .font(.system(.body, design: .rounded))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.04)))
            HStack {
                Button("Cancel", role: .cancel) { link.answer(approval, allow: false) }.buttonStyle(.bordered)
                Spacer()
                Button { link.answer(approval, allow: true) } label: { Label("Send", systemImage: "paperplane") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(MochiStyle.accent.opacity(0.5), lineWidth: 1.5))
    }
}
