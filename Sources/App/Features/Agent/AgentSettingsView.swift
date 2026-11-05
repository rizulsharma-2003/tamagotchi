import AppKit
import SwiftUI
import TamagotchiCore

/// Settings › Agent: Mochi keeps an eye on Gmail, Google Calendar and Notion.
struct AgentSettingsView: View {
    let environment: AppEnvironment
    @Bindable private var store: SettingsStore
    @State private var cloudMessage: (ok: Bool, message: String)?
    @State private var fireURL = ""
    @State private var fireToken = ""
    @State private var triggerProblem: String?
    @State private var watcherMessage: (ok: Bool, message: String)?
    @State private var newVIP = ""
    @State private var vipsChanged = false

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.settingsStore
    }

    private var agent: AgentController { environment.agent }
    private var name: String { store.settings.petName }

    var body: some View {
        Form {
            Section {
                Toggle("Let \(name) keep an eye on my mail, calendar and tasks", isOn: $store.settings.agent.enabled)
                Text("Every few minutes \(name) asks Claude Haiku what's new in Gmail, Google Calendar and Notion, using the "
                     + "connectors in your own Claude account, and tells you what matters. Its checks only read. Nothing is ever "
                     + "sent or deleted; the one change it can make is marking an email read when you tick it done (see "
                     + "below). It runs on your Claude subscription, with no API key.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(AgentSource.allCases) { source in sourceRow(source) }
                HStack {
                    Button("Check Connections") { Task { await agent.refreshConnections(forgetNotes: true) } }
                        .disabled(agent.checkingConnections)
                    if agent.checkingConnections { ProgressView().controlSize(.small) }
                }
            } header: {
                Text("Connections")
            } footer: {
                Text("Connect… opens your Claude account's connectors in the browser, where you choose which account to connect. "
                     + "\(name) notices when you're back. Checking is a short Haiku run that only looks for the connectors.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("How often") {
                Picker("Check every", selection: $store.settings.agent.intervalMinutes) {
                    ForEach(AgentSettings.intervals, id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Toggle("Quiet hours", isOn: $store.settings.agent.quietHours.enabled)
                HStack {
                    DatePicker("From", selection: minuteBinding(\.quietHours.startMinute), displayedComponents: .hourAndMinute)
                    DatePicker("to", selection: minuteBinding(\.quietHours.endMinute), displayedComponents: .hourAndMinute)
                }
                .disabled(!store.settings.agent.quietHours.enabled)
                Toggle("Morning briefing", isOn: $store.settings.agent.briefingEnabled)
                DatePicker("Briefing at", selection: minuteBinding(\.briefingMinute), displayedComponents: .hourAndMinute)
                    .disabled(!store.settings.agent.briefingEnabled)
                Text("Each check is one short Haiku run, about half a minute. You can also ask \(name) “what's pending?” with ⌥Space.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Tell me") {
                Toggle("In \(name)'s speech bubble", isOn: $store.settings.agent.tellInBubble)
                Toggle("With a badge on the menu bar", isOn: $store.settings.agent.tellWithBadge)
                Toggle("On my phones: notifications and a “Waiting for you” card in Mochi", isOn: $store.settings.agent.tellPhone)
                Toggle("Keep newsletters and automated mail off my phones", isOn: $store.settings.agent.phoneSkipsLowPriority)
                    .disabled(!store.settings.agent.tellPhone)
                if store.settings.agent.tellPhone, !environment.link.paired {
                    Label("Pair a phone in Settings › Phones › Mochi Link to get these on your phones.", systemImage: "iphone")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(store.settings.agent.vips, id: \.self) { vip in
                    HStack {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                        Text(vip)
                        Spacer()
                        Button {
                            store.settings.agent.vips.removeAll { $0 == vip }
                            vipsChanged = true
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove")
                    }
                }
                HStack {
                    TextField("Name, email address or @company.com", text: $newVIP)
                        .onSubmit(addVIP)
                    Button("Add", action: addVIP).disabled(newVIP.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(store.settings.agent.vips.isEmpty
                     ? "Add the people whose mail matters most. Once you have VIPs, only their mail (and meetings) gets the badge "
                        + "and rings your phones; other mail waits quietly on the card and in the briefings."
                     : "Only mail from these people (and meetings) rings; other mail waits quietly on the card and in the briefings.")
                    .font(.caption).foregroundStyle(.secondary)
                if vipsChanged, agent.cloudTriggerSaved {
                    Label("Copy the Watcher Script again (below) and run “setup” once more, so Mochi Cloud knows your VIPs too.",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("VIPs")
            }

            Section("When I mark something done") {
                Toggle("Mark the email read in Gmail", isOn: $store.settings.agent.markReadWhenDone)
                Text("Tap ✓ on anything in “Waiting for you” on your phone (or Done below) and it leaves the card on every "
                     + "device. With this on, \(name) also removes Gmail's unread mark from that thread — the only change "
                     + "\(name) ever makes to your mail, and only for what you marked.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("What \(name) can see") {
                ForEach(AgentSource.allCases) { source in
                    Label(source.whatMochiSees, systemImage: source.symbol)
                        .foregroundStyle(store.settings.agent.watches(source) ? .primary : .secondary)
                }
                Text("Claude reads these through your connectors and hands \(name) a short summary. This Mac keeps only what "
                     + "\(name) told you (below) for two weeks; your mail and pages stay where they are.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("An hourly Claude task in Anthropic's cloud does the same check while this Mac is off or offline and "
                     + "notifies your phones through Mochi Link. Set it up once at claude.ai/code with the mochi-cloud repository; "
                     + "news your Mac already told you arrives quietly, so nothing rings twice.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    // Mochi Link: the cloud joins the room as its own device; no push key needed.
                    Button("Copy Cloud Settings") { Task { cloudMessage = await agent.copyCloudLinkSettings() } }
                        .disabled(!environment.link.paired)
                    Button("Open claude.ai/code") { NSWorkspace.shared.open(URL(string: "https://claude.ai/code")!) }
                }
                if !environment.link.paired {
                    Label("Pair a phone in Settings › Phones › Mochi Link first: Mochi Cloud joins the same link.", systemImage: "link")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let cloudMessage {
                    Label(cloudMessage.message, systemImage: cloudMessage.ok ? "doc.on.clipboard" : "exclamationmark.triangle")
                        .foregroundStyle(cloudMessage.ok ? Color.green : Color.orange).font(.caption)
                }
                if agent.cloudTriggerSaved {
                    HStack {
                        Label("On iPhone, “Check now” can ask the cloud when this Mac doesn't answer", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                        Spacer()
                        Button("Remove") { agent.removeCloudTrigger() }
                    }
                    Text("Mochi Watcher, a small script in your own Google account, wakes the cloud only when new mail or a "
                         + "calendar change arrives (8:00–23:00), so Claude runs for real news instead of every hour.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Copy Watcher Script") { watcherMessage = agent.copyWatcherScript() }
                        Button("Open script.google.com") { NSWorkspace.shared.open(URL(string: "https://script.google.com/home/projects/create")!) }
                    }
                    if let watcherMessage {
                        Label(watcherMessage.message, systemImage: watcherMessage.ok ? "doc.on.clipboard" : "exclamationmark.triangle")
                            .foregroundStyle(watcherMessage.ok ? Color.green : Color.orange).font(.caption)
                    }
                } else {
                    TextField("Fire URL (from the task's API trigger)", text: $fireURL)
                    SecureField("Token", text: $fireToken)
                    HStack {
                        Button("Save") { triggerProblem = agent.saveCloudTrigger(url: fireURL, token: fireToken); if triggerProblem == nil { fireToken = "" } }
                            .disabled(fireURL.isEmpty || fireToken.isEmpty)
                        if let triggerProblem {
                            Label(triggerProblem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                        }
                    }
                    Text("The token can only start this one task. It's kept in your Keychain and shared with your iPhone through Mochi "
                         + "Link, end-to-end encrypted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Mochi Cloud (when this Mac is off)")
            }

            Section("Recent") {
                HStack {
                    Button("Check Now") { agent.checkNow() }
                    Button("Briefing Now") { agent.briefNow() }
                    if agent.running { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Forget") { agent.forgetNews() }.help("Forget what \(name) has told you, so the next check reports everything again")
                }
                .disabled(!store.settings.agent.enabled || agent.running)
                if let result = agent.lastResult {
                    Label(result, systemImage: "text.bubble").font(.caption).lineLimit(3)
                }
                if let error = agent.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
                if let at = agent.lastRunAt {
                    Text("Last looked \(at.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(agent.notes.prefix(12)) { note in noteRow(note) }
                if agent.notes.isEmpty {
                    Text("Nothing yet.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Each look is a short Haiku run, so only when the state isn't known yet.
            if agent.connections.isEmpty, !agent.checkingConnections { Task { await agent.refreshConnections() } }
        }
    }

    private func sourceRow(_ source: AgentSource) -> some View {
        let state = agent.connections[source]
        let connected = state == .connected
        return HStack {
            Image(systemName: source.symbol).frame(width: 20)
            Text(source.title)
            Spacer()
            if let state {
                Label(state.title, systemImage: connected ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .labelStyle(.titleAndIcon).font(.callout)
                    .foregroundStyle(connected ? Color.green : Color.orange)
            } else {
                Text(agent.checkingConnections ? "Checking…" : "Unknown").font(.callout).foregroundStyle(.secondary)
            }
            if !connected { Button("Connect…") { agent.connect() } }
            Toggle("Watch", isOn: Binding(get: { store.settings.agent.watches(source) },
                                          set: { store.settings.agent.setWatching(source, $0) }))
                .toggleStyle(.checkbox)
        }
    }

    private func noteRow(_ note: AgentNote) -> some View {
        let done = agent.isDone(note.id)
        return HStack(alignment: .top) {
            Image(systemName: done ? "checkmark.circle.fill" : note.source.symbol)
                .foregroundStyle(done ? Color.green : note.important ? Color.orange : Color.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if note.vip == true { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                    Text(note.title).font(.callout.weight(.medium)).lineLimit(1).strikethrough(done)
                }
                if let subject = note.subject { Text(subject).font(.callout).lineLimit(1) }
                Text(note.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .opacity(done ? 0.55 : 1)
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(Date(timeIntervalSince1970: note.at).formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
                if !done {
                    Button("Done") { agent.markDone(note) }
                        .controlSize(.small)
                        .help("Take it off “Waiting for you” here and on your phones")
                }
            }
        }
    }

    private func addVIP() {
        let vip = newVIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vip.isEmpty, !store.settings.agent.vips.contains(where: { $0.caseInsensitiveCompare(vip) == .orderedSame }) else {
            newVIP = ""
            return
        }
        store.settings.agent.vips.append(vip)
        newVIP = ""
        vipsChanged = true
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<AgentSettings, Int>) -> Binding<Date> {
        Binding {
            let minute = store.settings.agent[keyPath: keyPath]
            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        } set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            store.settings.agent[keyPath: keyPath] = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        }
    }
}
