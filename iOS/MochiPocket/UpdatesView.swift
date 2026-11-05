import SwiftUI
import TamagotchiCore

/// "Waiting for you" opened up: everything that's waiting, then the week's earlier updates by day. Swipe to mark
/// something done, tap to open it, pull down to check again, and let Mochi read it out.
struct UpdatesView: View {
    let link: MacLink
    let petName: String
    let checking: Bool
    let checkNow: () -> Void
    @State private var store = UpdatesStore.shared
    @State private var reader = UpdatesReader.shared
    @State private var drafting: AgentNote?
    @Environment(\.dismiss) private var dismiss

    private var waiting: [AgentNote] { store.waiting(in: link.agent) }

    var body: some View {
        NavigationStack {
            List {
                if let headline = link.agent?.headline, !headline.isEmpty {
                    Section {
                        Label {
                            Text(headline).font(.mochi(.subheadline)).foregroundStyle(Theme.ink)
                        } icon: {
                            IconTile(symbol: "sparkles", tint: Theme.tint)
                        }
                        .listRowBackground(Theme.surface)
                    }
                }
                Section {
                    if waiting.isEmpty {
                        Label {
                            Text("Nothing waiting. \(petName) will tell you when something comes in.")
                        } icon: {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.success)
                        }
                        .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
                        .listRowBackground(Theme.surface)
                    }
                    ForEach(waiting) { note in
                        UpdateRow(note: note, done: false) { withAnimation { store.toggleDone(note.id) } }
                            .swipeActions(edge: .trailing) { doneButton(note) }
                            .swipeActions(edge: .leading) { draftButton(note) }
                            .contextMenu { menu(note) }
                            .listRowBackground(Theme.surface)
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Waiting for you")
                        Spacer()
                        if waiting.count > 1 {
                            Button {
                                withAnimation { store.markDone(waiting.map(\.id)) }
                            } label: {
                                Label("Mark all done", systemImage: "checkmark.circle")
                                    .font(.mochi(.subheadline, .semibold))
                                    .foregroundStyle(Theme.tint)
                                    .frame(minHeight: Theme.touch)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Mark all \(waiting.count) done")
                        }
                    }
                    .font(.mochi(.title3, .bold))
                    .foregroundStyle(Theme.ink)
                    .textCase(nil)
                } footer: {
                    if let looked = link.agent?.lookedAt {
                        Text("Checked by \(link.lastCheckedBy == "cloud" ? "Mochi Cloud" : PocketLink.shared.host.yours) "
                             + Date(timeIntervalSince1970: looked).formatted(.relative(presentation: .named))
                             + ". Pull down to check again.")
                            .font(.mochi(.footnote))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
                ForEach(store.history(excluding: Set(waiting.map(\.id))), id: \.day) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            UpdateRow(note: entry.note, done: store.isDone(entry.id))
                                .swipeActions(edge: .trailing) { doneButton(entry.note) }
                                .swipeActions(edge: .leading) { draftButton(entry.note) }
                                .contextMenu { menu(entry.note) }
                                .listRowBackground(Theme.surface)
                        }
                    } header: {
                        Text(dayTitle(group.day)).font(.mochi(.headline)).foregroundStyle(Theme.inkSecondary).textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(PocketBackground())
            .refreshable { if !checking { checkNow() } }
            .navigationTitle("Updates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { reader.toggle(waiting) } label: {
                        Label(reader.speaking ? "Stop" : "Read aloud", systemImage: reader.speaking ? "stop.circle.fill" : "speaker.wave.2.fill")
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $drafting) { DraftReplySheet(note: $0, link: link) }
        }
        .tint(Theme.tint)
        .onDisappear { reader.stop() }
    }

    private func doneButton(_ note: AgentNote) -> some View {
        let isDone = store.isDone(note.id)
        return Button { withAnimation { store.toggleDone(note.id) } } label: {
            Label(isDone ? "Not done" : "Done", systemImage: isDone ? "arrow.uturn.backward" : "checkmark")
        }
        .tint(isDone ? .gray : .green)
    }

    @ViewBuilder
    private func draftButton(_ note: AgentNote) -> some View {
        if note.threadID != nil, link.draftsAvailable {
            Button { drafting = note } label: { Label("Draft reply", systemImage: "arrowshape.turn.up.left") }
                .tint(Theme.tint)
        }
    }

    @ViewBuilder
    private func menu(_ note: AgentNote) -> some View {
        if note.link != nil {
            Button { OpenLinks.open(note) } label: {
                Label(note.source == .notion ? "Open in Notion" : note.source == .calendar ? "Join the meeting" : "Open in Gmail",
                      systemImage: note.source == .calendar ? "video" : "arrow.up.right.square")
            }
        }
        if note.threadID != nil, note.link != nil {
            Button { OpenLinks.openInBrowser(note) } label: { Label("Open This Email in Safari", systemImage: "safari") }
        }
        if note.threadID != nil, link.draftsAvailable {
            Button { drafting = note } label: { Label("Draft a reply…", systemImage: "arrowshape.turn.up.left") }
        }
        Button { withAnimation { store.toggleDone(note.id) } } label: {
            Label(store.isDone(note.id) ? "Mark as not done" : "Mark as done", systemImage: "checkmark.circle")
        }
        Button { UIPasteboard.general.string = [note.title, note.subject, note.detail].compactMap { $0 }.joined(separator: " — ") } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Earlier today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month())
    }
}

/// One update: who or what, the subject, Mochi's one-line gist, and where tapping it goes (mail in the Gmail
/// app). With `onDone`, a checkbox marks it done (it turns green, then the row leaves); meetings with a video link
/// get a Join button. Every control has a 44-point touch area.
struct UpdateRow: View {
    let note: AgentNote
    var done = false
    var onDone: (() -> Void)?
    @State private var ticked = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var box: CGFloat = 24
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if dynamicTypeSize.isAccessibilitySize { joinButton.padding(.leading, 44) }
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Button {
                OpenLinks.open(note)
            } label: {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    IconTile(symbol: done ? "checkmark" : tileSymbol, tint: done ? Theme.success : tint)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if note.vip == true, !done {
                                Image(systemName: "star.fill").font(.mochi(.caption)).foregroundStyle(Theme.vip)
                                    .accessibilityLabel("VIP")
                            }
                            Text(note.title).font(.mochi(.subheadline, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                                .strikethrough(done)
                        }
                        if let subject = note.subject {
                            Text(subject).font(.mochi(.footnote, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                        }
                        Text(note.detail).font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary).lineLimit(2)
                        if note.important, note.source == .gmail, !done, onDone == nil {
                            Tag(text: "Needs you", tint: Theme.warning).padding(.top, 2)
                        }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    Spacer(minLength: Theme.Space.xs)
                }
                .padding(.vertical, Theme.Space.s)
                .contentShape(Rectangle())
                .opacity(done ? 0.6 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityHint(note.link == nil ? "" : note.source == .calendar ? "Joins the meeting" : "Opens it")
            if !dynamicTypeSize.isAccessibilitySize { joinButton }
            if let onDone, !done {
                Button {
                    guard !ticked else { return }
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) { ticked = true }
                    // Let the green tick show for a moment before the row leaves.
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        onDone()
                    }
                } label: {
                    Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: box, weight: .regular))
                        .foregroundStyle(ticked ? Theme.success : Theme.inkSecondary.opacity(0.75))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: Theme.touch, height: Theme.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .sensoryFeedback(.success, trigger: ticked) { _, now in now }
                .accessibilityLabel("Mark \(note.title) done")
            }
        }
    }

    /// "Join" for meetings with a video link.
    @ViewBuilder
    private var joinButton: some View {
        if isMeeting, !done, let link = note.link, let url = URL(string: link) {
            Button { OpenLinks.openApp(url) } label: {
                    Label("Join", systemImage: "video.fill")
                        .font(.mochi(.footnote, .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(Capsule().fill(Theme.tint))
                        .frame(minHeight: Theme.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ClayPressStyle())
                .accessibilityLabel("Join \(note.title)")
            }
    }

    /// A meeting whose link is a video call (not a calendar page).
    private var isMeeting: Bool { note.source == .calendar && note.link?.hasPrefix("https://") == true }

    private var tileSymbol: String {
        switch note.source {
        case .gmail: return "envelope.fill"
        case .calendar: return "calendar"
        case .notion: return "checklist"
        }
    }

    private var tint: Color {
        switch note.source {
        case .calendar: return Theme.tint
        case .notion: return Theme.indigo
        case .gmail: return note.important ? Theme.warning : Theme.inkSecondary
        }
    }
}

/// "Draft reply": Mochi Cloud reads the email and writes a reply into Gmail Drafts. It never sends anything.
struct DraftReplySheet: View {
    let note: AgentNote
    let link: MacLink
    @State private var words = ""
    @State private var phase = Phase.editing
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    enum Phase: Equatable { case editing, asking, asked, failed(String) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.title).font(.mochi(.subheadline, .semibold))
                        if let subject = note.subject { Text(subject).font(.mochi(.footnote, .medium)) }
                        Text(note.detail).font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
                    }
                }
                Section {
                    TextField("What should it say? (optional)", text: $words, axis: .vertical)
                        .lineLimit(2...6)
                        .focused($focused)
                        .disabled(phase == .asking || phase == .asked)
                } footer: {
                    Text("For example “say yes, Thursday 3 pm works” or “ask for the invoice again”. Leave it empty and Mochi "
                         + "writes a sensible reply. It lands in Gmail Drafts: nothing is sent until you send it.")
                }
                switch phase {
                case .asked:
                    Label("On its way. You'll get a notification when the draft is in Gmail (about a minute).", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                case .failed(let problem):
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                default:
                    EmptyView()
                }
            }
            .navigationTitle("Draft a reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(phase == .asked ? "Close" : "Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if phase == .asking {
                        ProgressView()
                    } else if phase != .asked {
                        Button("Draft It") { Task { await ask() } }.disabled(note.threadID == nil)
                    }
                }
            }
        }
        .tint(Theme.tint)
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
    }

    private func ask() async {
        guard let thread = note.threadID else { return }
        phase = .asking
        if let problem = await link.draftReply(threadID: thread, note: words) {
            phase = .failed(problem)
        } else {
            phase = .asked
            try? await Task.sleep(for: .seconds(1.6))
            dismiss()
        }
    }
}
