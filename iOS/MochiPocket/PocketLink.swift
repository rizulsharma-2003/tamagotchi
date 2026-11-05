import CryptoKit
import Observation
import SwiftUI
import TamagotchiCore
import UIKit
import VisionKit

/// Mochi Link on the iPhone: joining the Mac's room by scanning its QR code, and whether the Mac is connected. The
/// relay is the only way to the Mac: paired, Mochi Pocket talks to it in under a second; unpaired, it works on its own.
@MainActor
@Observable
final class PocketLink {
    static let shared = PocketLink()

    private(set) var credentials = LinkCredentialStore.load(accessGroup: LinkSeal.accessGroup)
    private(set) var status = RelayLinkStore.Status.offline
    private(set) var peers: [RelayLinkStore.Peer] = []
    private(set) var working = false
    private(set) var problem: String?

    /// The platform of the computer this phone last saw in its room, so its name doesn't change while the relay's
    /// device list loads.
    private var knownHostPlatform: LinkPlatform?

    var paired: Bool { credentials != nil }
    /// The computer this phone talks to, named for the screens: "your Mac", "your PC", "BELPL-LT-636 (Mac)".
    var host: LinkHostName {
        LinkPeerNames.host(in: peers, excluding: credentials?.device, pairedName: credentials?.peerName,
                           knownPlatform: knownHostPlatform)
    }
    /// Every computer in the room, labeled: "BELPL-LT-636 (Mac)", or two joined with "and".
    var hostList: String {
        LinkPeerNames.hostList(in: peers, excluding: credentials?.device, pairedName: credentials?.peerName,
                               knownPlatform: knownHostPlatform)
    }
    /// A computer in the room is connected right now.
    var hostOnline: Bool { LinkPeerNames.hosts(in: peers, excluding: credentials?.device).contains { $0.online } }
    /// The status pill once the relay is connected: "Mac online", "PC away since 2:02 PM".
    var hostPill: String {
        let host = self.host
        return host.online ? host.onlineText : host.awayText(since: host.lastSeen?.formatted(date: .omitted, time: .shortened))
    }

    private static let hostPlatformKey = "linkHostPlatform"
    #if DEBUG
    /// A sample room is on screen (`-demoLink`): the relay's (empty) presence mustn't replace it.
    @ObservationIgnored private var showingDemo = false
    #endif

    private init() {
        knownHostPlatform = Self.savedHostPlatform(room: credentials?.room)
    }

    /// The host platform saved for `room` ("<room>|<platform tag>").
    private static func savedHostPlatform(room: String?) -> LinkPlatform? {
        guard let room, let saved = UserDefaults.standard.string(forKey: hostPlatformKey) else { return nil }
        let parts = saved.split(separator: "|", maxSplits: 1).map(String.init)
        return parts.count == 2 && parts[0] == room ? LinkPlatform(tag: parts[1]) : nil
    }

    private func rememberHostPlatform() {
        guard let room = credentials?.room,
              let platform = LinkPeerNames.hosts(in: peers, excluding: credentials?.device).compactMap(\.linkPlatform).first,
              platform != knownHostPlatform else { return }
        knownHostPlatform = platform
        UserDefaults.standard.set("\(room)|\(platform.rawValue)", forKey: Self.hostPlatformKey)
    }

    /// At launch: talk through the relay if this phone is paired.
    func start() {
        MochiLink.use(credentials)
        storeLiveActivityKey()
        registerPush()
        NotificationCenter.default.addObserver(forName: .linkPresenceDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Back in the foreground: iOS closed the socket while the app was away.
    func resume() {
        MochiLink.relay?.reconnectNow()
    }

    func pair(with text: String) async {
        guard let code = PairingCode(string: text) else {
            problem = "That isn't a Mochi pairing code. On your Mac or PC: open Mochi's Settings › Phones › Pair a Phone."
            return
        }
        working = true
        problem = nil
        defer { working = false }
        do {
            let joined = try await LinkPairing.join(code, role: "pocket", platform: "iOS", name: UIDevice.current.name)
            guard LinkCredentialStore.save(joined, accessGroup: LinkSeal.accessGroup) else {
                problem = "Couldn't keep the link in the Keychain."
                return
            }
            credentials = joined
            knownHostPlatform = Self.savedHostPlatform(room: joined.room)
            MochiLink.use(joined)
            storeLiveActivityKey()
            registerPush()
            MacLink.shared.log("link: paired with \(code.name)")
        } catch {
            problem = error.localizedDescription
        }
    }

    func unpair() {
        if let credentials {
            // Leave the room on the relay too, so this phone's credential stops working.
            Task { try? await LinkPairing.remove(device: credentials.device, from: credentials) }
        }
        forget()
        refresh()
    }

    /// Drops the pairing on this phone only.
    private func forget() {
        LinkCredentialStore.delete(accessGroup: LinkSeal.accessGroup)
        LinkSeal.deleteLiveActivityKey()
        credentials = nil
        MochiLink.use(nil)
    }

    /// Tells the relay where to reach this phone: its notification address and the Live Activity addresses. They stay
    /// on the relay, which does the pushing (the Mac reads them only to know a Live Activity can be reached).
    func registerPush() {
        guard let relay = MochiLink.relay else { return }
        let store = MochiLink.store
        var tokens: [String: Any] = [:]
        if let device = store.string(.deviceToken) { tokens["device"] = device }
        if let start = store.string(.pushToStart) { tokens["pushToStart"] = start }
        if let updates = store.value(.updateTokens) as? [String: String] { tokens["updates"] = updates }
        guard !tokens.isEmpty else { return }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        relay.register(tokens: tokens, apnsEnv: environment, topic: "com.insideedge.mochi")
    }

    /// The widget's own key (derived from the room key) where it can read it while the phone is locked.
    private func storeLiveActivityKey() {
        guard let credentials, let raw = LinkCrypto.data(base64url: credentials.key), raw.count == 32 else {
            LinkSeal.deleteLiveActivityKey()
            return
        }
        LinkSeal.storeLiveActivityKey(LinkCrypto.liveActivityKey(from: SymmetricKey(data: raw)).withUnsafeBytes { Data($0) })
    }

    private func refresh() {
        #if DEBUG
        if showingDemo { return }
        #endif
        if paired, MochiLink.relay?.removed == true {
            // The computer unpaired (deleting the room) or removed this phone: the old pairing can't work again.
            let host = self.host.yoursCapitalized
            forget()
            problem = "\(host) unpaired this iPhone. Scan a new code to pair again."
            MacLink.shared.log("link: removed by the relay; forgot the pairing")
        }
        status = MochiLink.relay?.status ?? .offline
        peers = MochiLink.relay?.peers ?? []
        rememberHostPlatform()
    }

    #if DEBUG
    /// `-demoLink mac|macAway|pc|both` (Simulator screenshots): this phone paired in a sample room (with a Mac, a Mac
    /// that's asleep, a PC, or an asleep Mac and an online PC), without the relay.
    func showDemo(_ hosts: String) {
        showingDemo = true
        let key = LinkCrypto.base64url(Data(repeating: 7, count: 32))
        credentials = LinkCredentials(relay: "demo.invalid", room: "demo", device: "dev_phone", secret: "demo", key: key,
                                      role: "pocket", peerName: hosts == "pc" ? "DESKTOP-7" : "BELPL-LT-636")
        knownHostPlatform = nil
        status = .online
        let now = Date().timeIntervalSince1970
        var room = [RelayLinkStore.Peer(device: "dev_phone", role: "pocket", name: "iPhone", platform: "iOS", online: true, lastSeen: now)]
        if hosts != "pc" {
            room.append(.init(device: "dev_mac", role: "host", name: "BELPL-LT-636", platform: "macOS", online: hosts == "mac",
                              lastSeen: now - 3600))
        }
        if hosts == "pc" || hosts == "both" {
            room.append(.init(device: "dev_pc", role: "host", name: "DESKTOP-7", platform: "windows", online: true, lastSeen: now))
        }
        room.append(.init(device: "dev_android", role: "pocket", name: "realme RMX3242", platform: "android", online: true, lastSeen: now))
        peers = room
    }
    #endif
}

/// Settings › Mochi Link.
struct LinkCard: View {
    @State private var link = PocketLink.shared
    @State private var scanning = false
    @State private var confirmUnpair = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Mochi Link").font(.mochi(.headline)).foregroundStyle(Theme.ink)
                Spacer()
                if link.paired {
                    Tag(text: link.status == .online ? link.hostPill : "Connecting",
                        symbol: link.hostOnline ? "checkmark" : "moon.zzz.fill",
                        tint: link.hostOnline ? Theme.success : Theme.inkSecondary)
                }
            }
            if link.paired {
                Label("Paired with \(link.hostList)", systemImage: "link")
                    .font(.mochi(.subheadline)).foregroundStyle(Theme.ink)
                Text(link.hostOnline
                     ? "Messages reach \(link.host.yours) in under a second, end-to-end encrypted."
                     : "\(link.host.yoursCapitalized) isn't connected right now (asleep or off). What you send waits for it for 10 minutes.")
                    .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
                Button("Unpair", role: .destructive) { confirmUnpair = true }
                    .font(.mochi(.footnote))
            } else {
                Text("Not paired yet, so Mochi lives here on its own. Pair once to bring in your Mac or PC: the room follows it, "
                     + "what you say reaches it in under a second, and Claude's summaries and the Live Activity arrive here, "
                     + "end-to-end encrypted. On your Mac or PC: open Mochi's Settings › Phones › Pair a Phone, then scan the code.")
                    .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
                HStack(spacing: Theme.Space.s) {
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan the Code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!DataScannerViewController.isSupported || link.working)
                    Button {
                        if let text = UIPasteboard.general.string { Task { await link.pair(with: text) } }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(link.working)
                }
                if link.working {
                    ProgressView("Pairing…").font(.mochi(.footnote))
                }
            }
            if let problem = link.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.mochi(.footnote, .medium)).foregroundStyle(Theme.warning)
            }
        }
        .mochiCard()
        .sheet(isPresented: $scanning) {
            QRScanner { text in
                scanning = false
                Task { await link.pair(with: text) }
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("Unpair from \(link.host.name ?? link.host.yours)?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { link.unpair() }
        } message: {
            Text("Mochi stops hearing from \(link.host.yours) until you scan a new code.")
        }
    }
}

/// The camera, looking for a QR code; calls `found` with the first one.
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false

        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in items {
                guard !done, case .barcode(let code) = item, let text = code.payloadStringValue, text.hasPrefix("mochi://pair") else { continue }
                done = true
                scanner.stopScanning()
                found(text)
            }
        }
    }
}
