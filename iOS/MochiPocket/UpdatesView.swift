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
                        Label(headline, systemImage: "sparkles")
                            .font(.system(.subheadline, design: .rounded))
                    }
                }
                Section {
                    if waiting.isEmpty {
                        Text("Nothing waiting. \(petName) will tell you when something comes in.")
                            .font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary)
                    }
                    ForEach(waiting) { note in
                        UpdateRow(note: note, done: false) { withAnimation { store.toggleDone(note.id) } }
                            .swipeActions(edge: .trailing) { doneButton(note) }
                            .swipeActions(edge: .leading) { draftButton(note) }
                            .contextMenu { menu(note) }
                    }
                } header: {
                    Text("Waiting for you")
                } footer: {
                    if let looked = link.agent?.lookedAt {
                        Text("Checked by \(link.lastCheckedBy == "cloud" ? "Mochi Cloud" : "your Mac") "
                             + Date(timeIntervalSince1970: looked).formatted(.relative(presentation: .named))
                             + ". Pull down to check again.")
                    }
                }
                ForEach(store.history(excluding: Set(waiting.map(\.id))), id: \.day) { group in
                    Section(dayTitle(group.day)) {
                        ForEach(group.entries) { entry in
                            UpdateRow(note: entry.note, done: store.isDone(entry.id))
                                .swipeActions(edge: .trailing) { doneButton(entry.note) }
                                .swipeActions(edge: .leading) { draftButton(entry.note) }
                                .contextMenu { menu(entry.note) }
                        }
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
                if waiting.count > 1 {
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            withAnimation { store.markDone(waiting.map(\.id)) }
                        } label: {
                            Label("Mark all \(waiting.count) done", systemImage: "checkmark.circle")
                        }
                    }
                }
            }
            .sheet(item: $drafting) { DraftReplySheet(note: $0, link: link) }
        }
        .tint(MochiStyle.accent)
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
                .tint(MochiStyle.accent)
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
/// app). With `onDone`, a grey checkbox marks it done (it turns green, then the row leaves); meetings with a
/// video link get a Join button.
struct UpdateRow: View {
    let note: AgentNote
    var done = false
    var onDone: (() -> Void)?
    @State private var ticked = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                OpenLinks.open(note)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: done ? "checkmark.circle.fill" : note.source.symbol)
                        .foregroundStyle(done ? Color.green : tint)
                        .frame(width: 22)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if note.vip == true, !done {
                                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                                    .accessibilityLabel("VIP")
                            }
                            Text(note.title).font(.system(.subheadline, design: .rounded).weight(.semibold)).lineLimit(1)
                                .strikethrough(done)
                        }
                        if let subject = note.subject {
                            Text(subject).font(.system(.footnote, design: .rounded).weight(.medium)).lineLimit(1)
                        }
                        Text(note.detail).font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if note.important, note.source == .gmail, !done, onDone == nil {
                        Text("Needs you")
                            .font(.system(.caption2, design: .rounded).weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.orange.opacity(0.13)))
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .opacity(done ? 0.55 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityHint(note.link == nil ? "" : note.source == .calendar ? "Joins the meeting" : "Opens it")
            if isMeeting, !done, let link = note.link, let url = URL(string: link) {
                Button { OpenLinks.openApp(url) } label: {
                    Label("Join", systemImage: "video.fill")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(MochiStyle.accent.opacity(0.15)))
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }
            if let onDone, !done {
                Button {
                    guard !ticked else { return }
                    withAnimation(.spring(duration: 0.25)) { ticked = true }
                    // Let the green tick show for a moment before the row leaves.
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        onDone()
                    }
                } label: {
                    Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(ticked ? Color.green : Color.gray.opacity(0.55))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .sensoryFeedback(.success, trigger: ticked) { _, now in now }
                .accessibilityLabel("Mark \(note.title) done")
                .padding(.top, 2)
            }
        }
    }

    /// A meeting whose link is a video call (not a calendar page).
    private var isMeeting: Bool { note.source == .calendar && note.link?.hasPrefix("https://") == true }

    private var tint: Color {
        if note.source == .calendar { return MochiStyle.accent }
        return note.important ? .orange : .secondary
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
                        Text(note.title).font(.system(.subheadline, design: .rounded).weight(.semibold))
                        if let subject = note.subject { Text(subject).font(.system(.footnote, design: .rounded).weight(.medium)) }
                        Text(note.detail).font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary)
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
                        .foregroundStyle(.green)
                case .failed(let problem):
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
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
        .tint(MochiStyle.accent)
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
