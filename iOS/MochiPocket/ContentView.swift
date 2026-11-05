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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(coordinator: ActivityCoordinator, link: MacLink) {
        self.coordinator = coordinator
        self.link = link
        _talk = State(initialValue: TalkModel(link: link))
    }

    var body: some View {
        ZStack {
            PocketBackground()
            ScrollView {
                VStack(spacing: Theme.Space.l) {
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
                .padding(.horizontal, Theme.Space.l)
                .padding(.bottom, Theme.Space.xl + Theme.Space.s)
            }
            .scrollDisabled(talk.isHolding)
            // Simulator screenshots: `-demoScroll 1` opens at the bottom.
            .defaultScrollAnchor(UserDefaults.standard.bool(forKey: "demoScroll") ? .bottom : .top)
        }
        .tint(Theme.tint)
        .sheet(isPresented: $showSettings) { PocketSettingsView(coordinator: coordinator, link: link, phone: phone) }
        .sheet(isPresented: $showUpdates) {
            UpdatesView(link: link, petName: phone.world.settings.petName, checking: checkingForUpdates, checkNow: checkForUpdates)
        }
        .sheet(item: $drafting) { DraftReplySheet(note: $0, link: link) }
        .onChange(of: link.exchanges) { _, _ in talk.linkChanged() }
        .onChange(of: link.cloudAskedAt) { _, _ in talk.cloudTookOver() }
        .task {
            if let text = UserDefaults.standard.string(forKey: "sendCommand") { talk.send(typed: text) }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "kokoroTest") { await KokoroVoice.shared.selfTest() }
            if UserDefaults.standard.bool(forKey: "sealSpike") { coordinator.startSealedDemo() }
            // Spike 0.2: copy the extensions' log where devicectl can reach it (Documents).
            if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.insideedge.mochi"),
               let log = try? Data(contentsOf: group.appendingPathComponent("link-spike.txt")),
               let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? log.write(to: documents.appendingPathComponent("link-spike.txt"))
            }
            // Simulator screenshots: `-demoContent 1`, and `-openSheet settings|updates`.
            if UserDefaults.standard.bool(forKey: "demoContent") { link.showDemoContent() }
            switch UserDefaults.standard.string(forKey: "openSheet") {
            case "settings": showSettings = true
            case "updates": showUpdates = true
            default: break
            }
            #endif
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
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(phone.world.settings.petName)
                        .font(.mochi(.largeTitle, .heavy))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("and \(phone.world.settings.companionName), from your Mac")
                        .font(.mochi(.subheadline))
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                RoundIconButton(symbol: "gearshape.fill", label: "Settings", tint: Theme.inkSecondary) { showSettings = true }
            }
            HStack(spacing: Theme.Space.s) {
                let linked = phone.linkedToMac || (coordinator.iCloudAvailable && coordinator.hasPushToStartToken)
                StatusPill(text: linked ? "Mac linked" : "Not linked to your Mac",
                           symbol: linked ? "checkmark.icloud.fill" : "icloud.slash",
                           tint: linked ? Theme.success : Theme.inkSecondary)
                if phone.friendshipLevel > 0 {
                    StatusPill(text: "Friendship \(phone.friendshipLevel)", symbol: "heart.fill", tint: Theme.pet)
                }
            }
        }
        .padding(.top, Theme.Space.s)
    }

    // MARK: Room

    private var room: some View {
        VStack(spacing: Theme.Space.s) {
            ZStack(alignment: .top) {
                RoomView(phone: phone, talk: talk)
                    .frame(height: 290)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .background(ClaySurface())
                if let text = bubbleText {
                    SpeechBubble(text: text, highlighted: talk.isHolding)
                        .padding(.horizontal, 22)
                        .padding(.top, Theme.Space.m)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if talk.isBusy, !talk.isHolding {
                    RoundIconButton(symbol: "xmark", label: "Stop", tint: Theme.inkSecondary) { talk.cancel() }
                        .padding(Theme.Space.s)
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.3), value: bubbleText)
            Text(talk.isHolding ? "Listening… let go to send" : "Tap \(phone.world.settings.petName) to pet · press and hold to talk")
                .font(.mochi(.footnote, .medium))
                .foregroundStyle(talk.isHolding ? Theme.tint : Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var bubbleText: String? {
        talk.bubble ?? phone.world.activeSpeech?.text
    }

    // MARK: Actions

    /// Four across, or two by two when the text is very large.
    private var actions: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Space.s),
                            count: dynamicTypeSize.isAccessibilitySize ? 2 : 4)
        return LazyVGrid(columns: columns, spacing: Theme.Space.s) {
            ActionButton(title: "Pet", symbol: "heart.fill", tint: Theme.pet) { phone.interact(.pet) }
            ActionButton(title: "Play", symbol: "tennisball.fill", tint: Theme.play) { phone.interact(.play) }
            ActionButton(title: "Treat", symbol: "birthday.cake.fill", tint: Theme.warning) { phone.interact(.treat) }
            ActionButton(title: "Type", symbol: "keyboard.fill", tint: Theme.tint, selected: typing) {
                typing.toggle()
                fieldFocused = typing
            }
        }
    }

    private var typingField: some View {
        HStack(spacing: Theme.Space.s) {
            TextField("Tell \(phone.world.settings.petName) what to do on your Mac", text: $typed, axis: .vertical)
                .font(.mochi(.body))
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit(sendTyped)
                .padding(.horizontal, Theme.Space.m)
                .frame(minHeight: Theme.touch)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous).fill(Theme.sunken))
            Button(action: sendTyped) {
                Image(systemName: "arrow.up").font(.mochi(.body, .bold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Send")
        }
        .mochiCard(padding: Theme.Space.m)
    }

    private func sendTyped() {
        talk.send(typed: typed)
        typed = ""
        typing = false
        fieldFocused = false
    }

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionTitle(title: "Recently")
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(link.exchanges.suffix(3).reversed()) { exchange in
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        IconTile(symbol: icon(for: exchange.state), tint: color(for: exchange.state))
                        VStack(alignment: .leading, spacing: 2) {
                            if let project = exchange.project {
                                Text("To Claude in \(project)").font(.mochi(.caption, .semibold)).foregroundStyle(Theme.inkSecondary)
                            }
                            Text(exchange.text).font(.mochi(.subheadline, .semibold)).foregroundStyle(Theme.ink).lineLimit(2)
                            Text(exchange.reply ?? status(for: exchange.state))
                                .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary).lineLimit(3)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .mochiCard()
        }
    }

    private func icon(for state: MacLink.State) -> String {
        switch state {
        case .sending: return "paperplane.fill"
        case .working: return "gearshape.2.fill"
        case .done: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }

    private func color(for state: MacLink.State) -> Color {
        switch state {
        case .done: return Theme.success
        case .failed: return Theme.warning
        default: return Theme.tint
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionTitle(title: "Claude on your Mac",
                         note: link.sessions.isEmpty ? nil : "\(link.sessions.count) session\(link.sessions.count == 1 ? "" : "s")")
            if link.summariesShared != true {
                Label {
                    Text(link.summariesShared == false
                         ? "Turn on “Send Claude's summaries to my iPhone” in \(phone.world.settings.petName)'s Settings › iPhone on your Mac to see what each session did and reply to it here."
                         : "Waiting to hear from your Mac…")
                } icon: {
                    IconTile(symbol: "text.bubble.fill", tint: Theme.inkSecondary)
                }
                .font(.mochi(.footnote))
                .foregroundStyle(Theme.inkSecondary)
                .mochiCard()
            } else if link.sessions.isEmpty {
                Label {
                    Text("No Claude sessions right now. When one finishes, its summary shows up here.")
                } icon: {
                    IconTile(symbol: "moon.zzz.fill", tint: Theme.inkSecondary)
                }
                .font(.mochi(.footnote))
                .foregroundStyle(Theme.inkSecondary)
                .mochiCard()
            } else {
                ForEach(link.sessions) { card in
                    SessionCard(card: card) { text in talk.send(typed: text, project: card.project, session: card.id) }
                }
            }
        }
    }
}

/// A small pill under the name: whether the Mac is linked, the friendship level.
struct StatusPill: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).foregroundStyle(Theme.ink)
        }
        .font(.mochi(.footnote, .semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// A big clay action under the room: a coloured icon well over a dark label, a soft squish and a tap of haptics.
struct ActionButton: View {
    let title: String
    let symbol: String
    let tint: Color
    var selected = false
    let action: () -> Void
    @State private var taps = 0
    @ScaledMetric(relativeTo: .body) private var well: CGFloat = 40

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: well * 0.45, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : tint)
                    .frame(width: well, height: well)
                    .background(Circle().fill(selected ? tint : tint.opacity(0.12)))
                Text(title).font(.mochi(.footnote, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(ClaySurface(radius: 20))
            .contentShape(Rectangle())
        }
        .buttonStyle(ClayPressStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Mochi's speech bubble above the avatar.
struct SpeechBubble: View {
    let text: String
    var highlighted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(.mochi(.body, .medium))
            .foregroundStyle(Theme.ink)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(highlighted ? Color(hex: 0xFCE9DD) : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(highlighted ? Theme.tint : Theme.stroke, lineWidth: highlighted ? 2 : 1))
            .shadow(color: Theme.shadow.opacity(0.10), radius: 10, y: 4)
            .id(text)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
    }
}

/// A message your Mac wants to send to one of your Claude sessions, waiting for your OK.
struct ApprovalCard: View {
    let approval: MacLink.Approval
    let link: MacLink

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                IconTile(symbol: "paperplane.fill", tint: Theme.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Send to Claude?").font(.mochi(.headline)).foregroundStyle(Theme.ink)
                    Text(approval.project ?? approval.target).font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
                }
            }
            Text(approval.message)
                .font(.mochi(.body))
                .foregroundStyle(Theme.ink)
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous).fill(Theme.sunken))
            HStack {
                Button("Don't Send", role: .cancel) { link.answer(approval, allow: false) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Spacer()
                Button { link.answer(approval, allow: true) } label: { Label("Send", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .mochiCard()
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.tint.opacity(0.45), lineWidth: 1.5))
    }
}
