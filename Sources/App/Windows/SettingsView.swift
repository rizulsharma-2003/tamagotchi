import SwiftUI
import TamagotchiCore
import TamagotchiWire

/// Settings in MacTamagotchi's Liquid Glass style: on a calm dark (or light) base, a floating sidebar card on the
/// left and a floating content card on the right with the pane's big title, and glass capsules in the toolbar
/// (a status pill and search).
struct SettingsView: View {
    let environment: AppEnvironment
    @Bindable private var ui: UIState
    @State private var search = ""
    @FocusState private var searching: Bool

    init(environment: AppEnvironment) {
        self.environment = environment
        self.ui = environment.ui
    }

    private var groups: [(name: String, tabs: [SettingsTab])] {
        SettingsTab.groups.map { ($0.name, $0.tabs.filter { $0.matches(search) }) }.filter { !$0.tabs.isEmpty }
    }

    var body: some View {
        HStack(spacing: 14) {
            sidebar.frame(width: 252)
            content
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 6)
        .background(LiquidBackdrop(tab: ui.settingsTab))
        .frame(minWidth: 820, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .navigation) { titleItem }
            ToolbarItem(placement: .navigation) { StatusPill(environment: environment) { ui.settingsTab = .claude } }
        }
        .background(WindowTitle(title: ui.settingsTab.title))
        // ⌘F jumps to the sidebar's search field.
        .background(Button("Search") { searching = true }.keyboardShortcut("f", modifiers: .command).hidden())
    }

    private var titleItem: some View {
        HStack(spacing: 8) {
            SettingsIcon(tab: .about, size: 22, symbolOverride: "pawprint.fill")
            Text("MacTamagotchi").font(.system(size: 15, weight: .semibold))
        }
        .padding(.horizontal, 4)
    }

    // MARK: Sidebar card

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 12)
            if search.isEmpty {
                PetCard(environment: environment) { ui.settingsTab = .characters }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.name) { group in
                        Text(group.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 12)
                            .padding(.bottom, 3)
                        ForEach(group.tabs) { tab in
                            SidebarRow(tab: tab, selected: ui.settingsTab == tab) {
                                withAnimation(.snappy(duration: 0.22)) { ui.settingsTab = tab }
                            }
                        }
                    }
                    if groups.isEmpty {
                        Text("No settings match “\(search)”.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .settingsCard()
    }

    /// The search field at the top of the sidebar card: a glass capsule. Return opens the first match;
    /// Escape clears it.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searching)
                .onSubmit { if let first = groups.first?.tabs.first { ui.settingsTab = first } }
                .onExitCommand { search = "" }
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.primary.opacity(searching ? 0.09 : 0.06)))
        .overlay(Capsule().strokeBorder(searching ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                                        lineWidth: searching ? 1.5 : 0.5))
        .liquidGlass(cornerRadius: 18, interactive: true)
        .animation(.easeOut(duration: 0.15), value: searching)
        .animation(.snappy(duration: 0.2), value: search.isEmpty)
    }

    // MARK: Content card

    private var content: some View {
        let tab = ui.settingsTab
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                SettingsIcon(tab: tab, size: 44)
                    .shadow(color: tab.tint.opacity(0.35), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tab.title).font(.system(size: 26, weight: .bold))
                    Text(tab.blurb(pet: environment.settingsStore.settings.petName))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 4)
            pane(tab)
                .id(tab)
                .scrollContentBackground(.hidden)
                .glassButtons()
                .transition(.opacity)
        }
        .background(alignment: .top) {
            // A whisper of the pane's colour at the top of the card.
            LinearGradient(colors: [tab.tint.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 160)
                .animation(.easeInOut(duration: 0.3), value: tab)
        }
        .settingsCard()
    }

    @ViewBuilder
    private func pane(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettings(environment: environment)
        case .characters: CharacterSettings(environment: environment)
        case .claude: ClaudeSettings(environment: environment)
        case .assistant: AssistantSettingsView(environment: environment)
        case .iphone: PhoneSettingsView(environment: environment)
        case .agent: AgentSettingsView(environment: environment)
        case .notifications: NotificationSettings(environment: environment)
        case .desktop: DesktopSettings(environment: environment)
        case .fun: FunSettings(environment: environment)
        case .privacy: PrivacySettings(environment: environment)
        case .developer: DeveloperSettings(environment: environment)
        case .about: AboutSettings(environment: environment)
        }
    }
}

/// One sidebar row: the icon tile and name; the open pane sits on an accent-coloured glass pill.
private struct SidebarRow: View {
    let tab: SettingsTab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsIcon(tab: tab, size: 24)
                Text(tab.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [Color.accentColor.blended(0.12, with: .white), Color.accentColor],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 6, y: 2)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The toolbar's status pill: is Claude Code connected? Click it for the Claude Code pane.
private struct StatusPill: View {
    let environment: AppEnvironment
    let open: () -> Void

    var body: some View {
        let connection = environment.world.connection
        let (color, text): (Color, String) = switch connection.level {
        case .good: (.green, "Connected to Claude Code")
        case .waiting: (.yellow, connection.integration == .installed ? "Waiting for a Claude session" : "Checking Claude Code…")
        case .setupNeeded: (.orange, "Claude Code not connected")
        case .problem: (.red, "Claude Code needs attention")
        }
        Button(action: open) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                    .shadow(color: color.opacity(0.6), radius: 3)
                Text(text).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 6)
        }
        .help(connection.title)
    }
}

/// The two surfaces of the Settings window.
enum SettingsPalette {
    /// The calm base the cards float on: near-black in dark mode, soft grey in light mode.
    static let base = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.075, green: 0.075, blue: 0.085, alpha: 1)
            : NSColor(srgbRed: 0.90, green: 0.90, blue: 0.92, alpha: 1)
    })
    /// The cards: a step lighter than the base (under the glass).
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.135, green: 0.135, blue: 0.15, alpha: 1)
            : NSColor(srgbRed: 0.985, green: 0.985, blue: 0.99, alpha: 1)
    })
}

extension View {
    /// A floating card: rounded, a step lighter than the base, with Liquid Glass's light rim.
    func settingsCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return self
            .clipShape(shape)
            .background(SettingsPalette.card.opacity(0.62), in: shape)
            .liquidGlass(cornerRadius: 24)
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.03)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

extension SettingsTab {
    /// The sidebar's groups.
    static let groups: [(name: String, tabs: [SettingsTab])] = [
        ("Your pet", [.general, .characters, .desktop, .fun]),
        ("Claude", [.claude, .assistant, .agent]),
        ("Phones & alerts", [.iphone, .notifications]),
        ("App", [.privacy, .developer, .about]),
    ]

    var title: String {
        switch self {
        case .general: "General"
        case .characters: "Characters"
        case .claude: "Claude Code"
        case .assistant: "Assistant"
        case .iphone: "Phones"
        case .agent: "Agent"
        case .notifications: "Notifications"
        case .desktop: "Desktop Pet"
        case .fun: "Fun"
        case .privacy: "Privacy"
        case .developer: "Developer"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .characters: "pawprint.fill"
        case .claude: "chevron.left.forwardslash.chevron.right"
        case .assistant: "wand.and.stars"
        case .iphone: "iphone"
        case .agent: "tray.full.fill"
        case .notifications: "bell.badge.fill"
        case .desktop: "macwindow"
        case .fun: "sparkles"
        case .privacy: "hand.raised.fill"
        case .developer: "hammer.fill"
        case .about: "info.circle.fill"
        }
    }

    /// The icon tile's colour: Apple's system colours, one hue per pane so neighbours never blur together
    /// (warm for your pet, cool for devices and privacy, Claude's own terracotta for Claude Code).
    var tint: Color {
        switch self {
        case .general: Color(hex: 0x8E8E93)        // graphite
        case .characters: Color(hex: 0xFF9500)     // orange: your pet
        case .desktop: Color(hex: 0x30B0C7)        // teal
        case .fun: Color(hex: 0xFF2D55)            // pink
        case .claude: Color(hex: 0xD97757)         // Claude terracotta
        case .assistant: Color(hex: 0xAF52DE)      // purple
        case .agent: Color(hex: 0x34C759)          // green: always watching
        case .iphone: Color(hex: 0x5856D6)         // indigo
        case .notifications: Color(hex: 0xFF3B30)  // red
        case .privacy: Color(hex: 0x007AFF)        // blue
        case .developer: Color(hex: 0x636366)      // dark graphite
        case .about: Color(hex: 0xFF9F6E)          // Mochi's peach
        }
    }

    /// The pane's soft background glow: its own colour and a neighbouring one, so the glass has light to catch
    /// without shouting.
    var glow: (Color, Color) {
        switch self {
        case .general: (Color(hex: 0x7D8FB3), Color(hex: 0xFFB38A))
        case .characters: (Color(hex: 0xFF9500), Color(hex: 0xFF6482))
        case .desktop: (Color(hex: 0x30B0C7), Color(hex: 0x5AC8FA))
        case .fun: (Color(hex: 0xFF2D55), Color(hex: 0xBF5AF2))
        case .claude: (Color(hex: 0xD97757), Color(hex: 0xF2C48D))
        case .assistant: (Color(hex: 0xAF52DE), Color(hex: 0x5E5CE6))
        case .agent: (Color(hex: 0x34C759), Color(hex: 0x30B0C7))
        case .iphone: (Color(hex: 0x5856D6), Color(hex: 0x0A84FF))
        case .notifications: (Color(hex: 0xFF3B30), Color(hex: 0xFF9F0A))
        case .privacy: (Color(hex: 0x007AFF), Color(hex: 0x64D2FF))
        case .developer: (Color(hex: 0x636366), Color(hex: 0x30B0C7))
        case .about: (Color(hex: 0xFF9F6E), Color(hex: 0xBF5AF2))
        }
    }

    /// The pane's header line.
    var blurb: String { blurb(pet: "Mochi") }

    func blurb(pet: String) -> String {
        switch self {
        case .general: "Startup, how \(pet) lives in the menu bar, reactions and quiet hours."
        case .characters: "Names, looks and personalities for your pet and your coding companion."
        case .claude: "Connect Claude Code so your companion joins your sessions and reacts to what they do."
        case .assistant: "Talk to \(pet) with ⌥Space: ask questions, run quick commands and reach your Claude sessions."
        case .iphone: "Mochi on your phones: pairing, Claude's summaries and replies, and the iPhone's Live Activity."
        case .agent: "\(pet) keeps an eye on Gmail, Google Calendar and Notion and tells you what matters."
        case .notifications: "Which moments get a notification, and how they sound."
        case .desktop: "Let \(pet) and friends wander on your desktop, above your windows."
        case .fun: "Games, adventures, seasons and little surprises."
        case .privacy: "What MacTamagotchi keeps, where it stays, and how to clear it."
        case .developer: "Diagnostics, the event simulator and tools for testing."
        case .about: "Version, credits and how to uninstall."
        }
    }

    /// Extra words the sidebar search finds this pane by.
    var keywords: String {
        switch self {
        case .general: "login startup menu bar roam stage icon reactions quiet hours pause"
        case .characters: "pet companion name colour color accessory personality patch mochi look"
        case .claude: "hooks connect sessions integration claude code helper"
        case .assistant: "ask mochi voice talk shortcut option space quick commands brain"
        case .iphone: "phones phone iphone android mochi pocket pair pairing link live activity push summaries replies"
        case .agent: "gmail calendar notion mail meetings tasks briefing vip done cloud watcher"
        case .notifications: "alerts sounds banner"
        case .desktop: "desktop pet wander window floor"
        case .fun: "games adventure seasons treats achievements focus"
        case .privacy: "data history retention clear journal"
        case .developer: "debug simulator diagnostics logs"
        case .about: "version credits uninstall"
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        let haystack = (title + " " + keywords + " " + blurb).lowercased()
        return query.split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}

/// Keeps the window's title on the open pane (as System Settings does).
private struct WindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window, window.title != title { window.title = title }
        }
    }
}

/// A Liquid Glass icon tile: a white symbol on a softly lit colour tile, brighter at the top with a specular
/// sheen and a fine light rim, like Apple's own.
struct SettingsIcon: View {
    let tab: SettingsTab
    var size: CGFloat = 22
    var symbolOverride: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        shape
            .fill(LinearGradient(colors: [tab.tint.blended(0.22, with: .white), tab.tint, tab.tint.blended(0.10, with: .black)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                // The sheen: light falling on the upper half.
                shape.fill(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0.0)], startPoint: .top, endPoint: .center))
                    .blendMode(.plusLighter)
                    .opacity(0.55)
            )
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom),
                                   lineWidth: max(0.5, size / 44))
            )
            .overlay(
                Image(systemName: symbolOverride ?? tab.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: tab.tint.blended(0.45, with: .black).opacity(0.35), radius: size / 30, y: size / 40)
            )
            .frame(width: size, height: size)
    }
}

/// The window's backdrop: the calm base with two blurred glows in the open pane's colours, which the glass
/// cards float over and bend.
struct LiquidBackdrop: View {
    let tab: SettingsTab
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let (first, second) = tab.glow
        let strength = scheme == .dark ? 1.0 : 0.7
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            ZStack {
                SettingsPalette.base
                Ellipse()
                    .fill(first.opacity(0.42 * strength))
                    .frame(width: w * 0.75, height: h * 0.6)
                    .offset(x: w * 0.25, y: -h * 0.28)
                    .blur(radius: 110)
                Ellipse()
                    .fill(second.opacity(0.30 * strength))
                    .frame(width: w * 0.7, height: h * 0.55)
                    .offset(x: -w * 0.28, y: h * 0.30)
                    .blur(radius: 120)
            }
            .frame(width: w, height: h)
            .drawingGroup()
        }
        .animation(.easeInOut(duration: 0.45), value: tab)
        .ignoresSafeArea()
    }
}

extension View {
    /// Liquid Glass on macOS 26 and later; a thin material before.
    @ViewBuilder
    func liquidGlass(tint: Color? = nil, cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// Glass push buttons (macOS 26 and later).
    @ViewBuilder
    func glassButtons() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glass) } else { self }
    }

}

extension Color {
    /// This colour moved `fraction` of the way to `other` (AppKit's blend, so it works before macOS 15).
    func blended(_ fraction: CGFloat, with other: NSColor) -> Color {
        let base = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return Color(nsColor: base.blended(withFraction: fraction, of: other) ?? base)
    }

    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// The card at the top of the sidebar (where System Settings shows your account): your pet, live.
private struct PetCard: View {
    let environment: AppEnvironment
    let open: () -> Void

    var body: some View {
        let settings = environment.world.settings
        Button(action: open) {
            HStack(spacing: 10) {
                SceneView(world: environment.world, style: .desktop, visible: true, showCompanion: false, maxFrameRate: 15)
                    .frame(width: 44, height: 40)
                    .background(Circle().fill(SettingsTab.about.tint.opacity(0.22)).frame(width: 40, height: 40))
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(settings.petName).font(.headline)
                    Text("with \(settings.companionName) · Friendship \(environment.world.progress.friendshipLevel)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Change how \(settings.petName) looks")
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let environment: AppEnvironment
    @Bindable private var store: SettingsStore
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var loginError: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.settingsStore
    }

    private func roamHelp(name: String, range: MenuBarRoamRange) -> String {
        let reach: String
        switch range {
        case .near: reach = "stays within about 100 pt either side of its bed"
        case .wide: reach = "roams about 200 pt either side of its bed"
        case .full: reach = "roams the whole free stretch of the menu bar"
        }
        return "\(name) lives in a little bed at the menu-bar item and \(reach), walking, running and playing in full colour. It romps across other apps' icons but only rests where the bar is free, never goes near the clock, the notch or the app menus, and clicks always go through to what is underneath. While Claude Code works or waits for you, \(name) stays home beside \(store.settings.companionName). Right-click the item to pet, play or give a treat."
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open MacTamagotchi at login", isOn: Binding(get: { loginEnabled }, set: { value in
                    loginError = LoginItem.set(value)
                    loginEnabled = LoginItem.isEnabled
                }))
                Text(loginError ?? LoginItem.statusDescription).font(.caption).foregroundStyle(.secondary)
                Button("Show Welcome Again") { environment.windows.showWelcome() }
            }
            Section("Menu bar") {
                Picker("Style", selection: $store.settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                let name = store.settings.petName
                switch store.settings.menuBarStyle {
                case .roam:
                    Picker("Roaming range", selection: $store.settings.menuBarRoamRange) {
                        ForEach(MenuBarRoamRange.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(roamHelp(name: name, range: store.settings.menuBarRoamRange))
                        .font(.caption).foregroundStyle(.secondary)
                    if let note = environment.ui.menuBarNote {
                        Text(note).font(.caption).foregroundStyle(.orange)
                    }
                case .stage:
                    Picker("Width", selection: $store.settings.menuBarStageWidth) {
                        ForEach(MenuBarStageWidth.allCases) { Text("\($0.title) (\(Int($0.points)) pt)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("\(name) plays inside a wider menu-bar item, in full colour.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let note = environment.ui.menuBarNote {
                        Text(note).font(.caption).foregroundStyle(.orange)
                    }
                case .icon:
                    Picker("Icon animation", selection: $store.settings.menuBarAnimation) {
                        ForEach(MenuBarAnimation.allCases) { Text($0.title).tag($0) }
                    }
                    Text("The original monochrome icon: blinks, an antenna pulse while Claude works and a hop when a turn completes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Reactions") {
                Toggle("Pause all reactions", isOn: $store.settings.pauseReactions)
                Text("Sessions and history keep updating; the characters stop reacting and nothing plays sounds or sends notifications.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Quiet mode", isOn: $store.settings.quietMode)
            }
            Section("Quiet hours") {
                Toggle("Quiet hours", isOn: $store.settings.quietHours.enabled)
                HStack {
                    DatePicker("From", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                    DatePicker("to", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
                }
                .disabled(!store.settings.quietHours.enabled)
                Text("During quiet hours and quiet mode there are no sounds or notification banners. Animations and badges still show.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Motion") {
                Picker("Animation intensity", selection: $store.settings.animationIntensity) {
                    ForEach(AnimationIntensity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Reduce motion", selection: $store.settings.reducedMotion) {
                    ForEach(ReducedMotionPreference.allCases) { Text($0.title).tag($0) }
                }
                Text(environment.world.reducedMotion
                     ? "Reduced motion is on: no jumping, spinning or walking — expressions and gentle fades only."
                     : "Full motion. macOS Reduce Motion is \(environment.world.systemReducedMotion ? "on" : "off").")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<QuietHours, Int>) -> Binding<Date> {
        Binding {
            let minute = store.settings.quietHours[keyPath: keyPath]
            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        } set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            store.settings.quietHours[keyPath: keyPath] = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        }
    }
}

// MARK: - Characters

private struct CharacterSettings: View {
    let environment: AppEnvironment
    @Bindable private var store: SettingsStore
    @State private var confirmReset = false

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.settingsStore
    }

    private var unlocked: Set<AchievementID> { environment.world.progress.unlockedIDs }

    var body: some View {
        Form {
            Section {
                SceneView(world: environment.world, style: .popover, visible: true)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .listRowInsets(EdgeInsets())
            }
            Section("Names") {
                TextField("Your pet", text: $store.settings.petName)
                TextField("Coding companion", text: $store.settings.companionName)
            }
            Section("Look") {
                LabeledContent("Coat") {
                    HStack(spacing: 8) {
                        ForEach(PetColor.allCases) { color in
                            Button {
                                store.settings.petColor = color
                            } label: {
                                Circle()
                                    .fill(PetPalette(color).body)
                                    .overlay(Circle().strokeBorder(PetPalette(color).outline, lineWidth: 1.5))
                                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: store.settings.petColor == color ? 2.5 : 0).padding(-3))
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .help(color.title)
                            .accessibilityLabel(color.title)
                        }
                    }
                }
                accessoryPicker("\(store.settings.petName) wears", selection: $store.settings.petAccessory, slot: .wearable)
                accessoryPicker("\(store.settings.companionName) wears", selection: $store.settings.companionAccessory, slot: .wearable)
                accessoryPicker("On the desk", selection: $store.settings.deskAccessory, slot: .desk)
                Picker("Office theme", selection: $store.settings.theme) {
                    ForEach(OfficeTheme.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Naps") {
                Toggle("Sleep while my Mac rests, awake while I work", isOn: $store.settings.followSystem)
                Stepper("Rests after \(store.settings.restAfterMinutes) min without typing or clicking",
                        value: $store.settings.restAfterMinutes, in: 1...60)
                    .disabled(!store.settings.followSystem)
                Text("\(store.settings.petName) also sleeps when your displays do, stays up while a video or call keeps the "
                     + "screen on, Claude is working or the Mac is busy, and wakes with a stretch when you're back. Only the "
                     + "time since your last input is read, never what you type.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Companion") {
                Picker("Show \(store.settings.companionName)", selection: $store.settings.companionVisibility) {
                    ForEach(CompanionVisibility.allCases) { Text($0.title).tag($0) }
                }
                Stepper("Stays \(store.settings.companionLingerMinutes) min after the last session ends", value: $store.settings.companionLingerMinutes, in: 0...120, step: 5)
                Stepper("Naps after \(store.settings.companionSleepAfterMinutes) min without events", value: $store.settings.companionSleepAfterMinutes, in: 1...60)
            }
            Section("Friendship") {
                let progress = environment.world.progress
                LabeledContent("Friendship level") {
                    HStack(spacing: 3) {
                        ForEach(0..<5, id: \.self) { index in
                            Image(systemName: index < progress.friendshipLevel ? "heart.fill" : "heart")
                                .foregroundStyle(index < progress.friendshipLevel ? Color.pink : Color.secondary)
                        }
                        Text("\(progress.affectionPoints) points").foregroundStyle(.secondary)
                    }
                }
                Text("Petting, playing and treats earn a few points a day (with daily caps). Points never go down, and nothing bad happens if you're away.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(AchievementID.allCases) { id in
                    HStack(alignment: .top) {
                        Image(systemName: progress.unlocked[id.rawValue] != nil ? "checkmark.seal.fill" : "seal")
                            .foregroundStyle(progress.unlocked[id.rawValue] != nil ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(id.title).font(.system(size: 12, weight: .medium))
                            Text(id.criteria + (id.reward.map { " Unlocks: \($0.title)." } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let date = progress.unlocked[id.rawValue] {
                            Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Reset Progress…", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset friendship and achievements?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { environment.achievements.reset() }
        }
    }

    private func accessoryPicker(_ title: String, selection: Binding<Accessory?>, slot: AccessorySlot) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(Accessory?.none)
            ForEach(Accessory.allCases.filter { $0.slot == slot }) { accessory in
                let available = accessory.isAvailable(unlocked: unlocked, date: Date())
                Text(available ? accessory.title : "\(accessory.title) — \(accessory.unlockHint)")
                    .tag(Accessory?.some(accessory))
                    .selectionDisabled(!available)
            }
        }
    }
}

// MARK: - Notifications

private struct NotificationSettings: View {
    let environment: AppEnvironment
    @Bindable private var store: SettingsStore
    @State private var authorization: NotificationCoordinator.Authorization = .unknown

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.settingsStore
    }

    var body: some View {
        Form {
            Section("Sound") {
                Toggle("Play sounds", isOn: $store.settings.soundEnabled)
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $store.settings.soundVolume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    Button("Test") { environment.play(.success) }
                }
                .disabled(!store.settings.soundEnabled)
                Toggle("Tiny keyboard taps while Claude edits or runs commands", isOn: $store.settings.workSounds)
                    .disabled(!store.settings.soundEnabled)
                if !SoundPlayer.systemUISoundsEnabled {
                    Text("“Play user interface sound effects” is off in System Settings › Sound, so MacTamagotchi stays silent too.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Notification Center") {
                LabeledContent("Permission") {
                    HStack {
                        Text(description(authorization)).foregroundStyle(.secondary)
                        if authorization == .notDetermined || authorization == .unknown {
                            Button("Allow…") { Task { _ = await environment.notifications.requestAuthorization(); await refresh() } }
                        }
                    }
                }
                Text("Banners are off for every category by default. Repeated events are batched, and nothing is sent for simulated or late events.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Per category") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("")
                        Text("Animate").font(.caption).foregroundStyle(.secondary)
                        Text("Badge").font(.caption).foregroundStyle(.secondary)
                        Text("Banner").font(.caption).foregroundStyle(.secondary)
                        Text("Sound").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(NotificationCategory.allCases) { category in
                        GridRow {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(category.title).font(.system(size: 12, weight: .medium))
                                Text(category.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            toggle(category, \.animate, enabled: true)
                            toggle(category, \.badge, enabled: category.allowsBadge)
                            toggle(category, \.banner, enabled: category.allowsBanner && environment.notifications.isAvailable)
                            toggle(category, \.sound, enabled: store.settings.soundEnabled)
                        }
                    }
                }
                Button("Restore Defaults") { store.settings.categoryDelivery = [:] }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    private func refresh() async {
        await environment.notifications.refreshAuthorization()
        authorization = environment.notifications.authorization
    }

    private func description(_ authorization: NotificationCoordinator.Authorization) -> String {
        switch authorization {
        case .allowed: return "Allowed"
        case .denied: return "Denied — change it in System Settings › Notifications"
        case .notDetermined: return "Not requested yet"
        case .unavailable: return "Unavailable when running outside the app bundle"
        case .unknown: return "Unknown"
        }
    }

    private func toggle(_ category: NotificationCategory, _ keyPath: WritableKeyPath<CategoryDelivery, Bool>, enabled: Bool) -> some View {
        Toggle("", isOn: Binding {
            store.settings.delivery(for: category)[keyPath: keyPath]
        } set: { value in
            var delivery = store.settings.delivery(for: category)
            delivery[keyPath: keyPath] = value
            store.settings.setDelivery(delivery, for: category)
            if keyPath == \.banner, value {
                Task { _ = await environment.notifications.requestAuthorization(); await refresh() }
            }
        })
        .labelsHidden()
        .toggleStyle(.checkbox)
        .disabled(!enabled)
    }
}

// MARK: - Desktop pet

private struct DesktopSettings: View {
    let environment: AppEnvironment
    @Bindable private var store: SettingsStore

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.settingsStore
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show desktop pet", isOn: binding(\.desktopPetEnabled))
                Text("Show or hide it any time with \(HotKey.displayString), the menu bar, or right-click › Hide.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Window") {
                Toggle("Always on top", isOn: binding(\.desktopPetAlwaysOnTop))
                Picker("Size", selection: binding(\.desktopPetSize)) {
                    ForEach(DesktopPetSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Let clicks pass through the pet", isOn: binding(\.desktopPetClickThrough))
                Text(store.settings.desktopPetClickThrough
                     ? "Clicks go to the app underneath, so the pet can't be dragged or petted. Hide it with \(HotKey.displayString) or the menu bar."
                     : "Drag the pet to move it; click to pet; right-click for options. Transparent areas around it don't catch clicks.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset Position") {
                    store.settings.desktopPetPosition = nil
                    environment.desktopPet.applySettings()
                }
            }
            Section("Companion") {
                Toggle("Show \(store.settings.companionName) during interesting Claude Code moments", isOn: binding(\.desktopPetShowsCompanion))
                Text("\(store.settings.companionName) appears for arrivals, waiting-for-you, errors and celebrations, then leaves so the pet stays compact while you work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding {
            store.settings[keyPath: keyPath]
        } set: { value in
            store.settings[keyPath: keyPath] = value
            environment.desktopPet.applySettings()
        }
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    let environment: AppEnvironment
    @Bindable private var store: SettingsStore
    @State private var confirmClear = false

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.settingsStore
    }

    var body: some View {
        Form {
            Section("What MacTamagotchi receives") {
                Text("""
                For each Claude Code hook event the helper forwards only: the event name, session id, project folder name (plus a one-way hash and, in memory only, its path), tool name and tool-use id, a tool category, an exit code number, whether a Bash command looked like a build or test (never the command itself), notification type and Claude Code's short notification text, subagent type, session start source / end reason, API error type and model name.
                """)
                .font(.callout)
                Text("Never received: prompts, tool inputs, file contents, command output, error text, assistant messages or transcript paths. Those are dropped inside the hook helper before anything leaves the Claude Code process.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("What is kept") {
                Picker("Keep event history for", selection: $store.settings.historyRetentionDays) {
                    Text("Don't keep history").tag(0)
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                Toggle("Store full project paths in history", isOn: $store.settings.storeProjectPaths)
                Toggle("Keep Claude Code's notification text", isOn: $store.settings.keepNotificationText)
                Text("History is a local JSON Lines file at \(environment.paths.journalFile.path) (at most 2,000 events). Simulated events are never stored.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                    Button("Show Data Folder") { NSWorkspace.shared.activateFileViewerSelecting([environment.paths.home]) }
                }
            }
            Section("The agent (off unless you turn it on)") {
                Text("With Settings › Agent on, a short background Claude Haiku run reads new mail, coming events and open tasks "
                     + "through the Gmail, Google Calendar and Notion connectors in your Claude account, with read-only tools. "
                     + "This Mac keeps only what \(store.settings.petName) told you, at \(environment.paths.agentFile.path), for two weeks.")
                    .font(.callout)
            }
            Section("Never") {
                Label("Monitors keystrokes, reads the clipboard, records audio or captures the screen", systemImage: "xmark.circle")
                Label("Inspects your documents or uploads anything — there is no server", systemImage: "xmark.circle")
                Label("Opens a network port — events use a private Unix socket only your user can reach", systemImage: "xmark.circle")
                Label("Changes Claude Code settings without your explicit Connect / Disconnect", systemImage: "xmark.circle")
            }
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear all stored history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                environment.world.clearHistory()
                environment.focus.log.clear()
            }
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    let environment: AppEnvironment

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    SceneView(world: environment.world, style: .desktop, visible: true, showCompanion: true)
                        .frame(width: 220, height: 96)
                        .allowsHitTesting(false)
                    Text("MacTamagotchi").font(.system(size: 22, weight: .bold))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · hook helper \(HelperInfo.version)")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("A tiny digital friendship between you, your pet and your AI coding companion.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            Section("Uninstall") {
                Text("1. Settings › Claude Code › Disconnect (removes only MacTamagotchi's hook entries, after a backup).\n2. Quit and move MacTamagotchi to the Trash.\n3. Optionally delete \(environment.paths.home.path).")
                    .font(.callout)
                    .textSelection(.enabled)
            }
            Section("Characters") {
                Text("Mochi and Patch are original characters drawn procedurally with vector shapes. Patch is inspired by AI coding assistants in spirit only and uses no third-party logos or artwork.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
