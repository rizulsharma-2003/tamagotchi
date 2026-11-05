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

    var paired: Bool { credentials != nil }
    var macName: String { credentials?.peerName ?? "your Mac" }
    /// A computer in the room is connected right now.
    var macOnline: Bool { peers.contains { $0.role == "host" && $0.online } }

    private init() {}

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
            problem = "That isn't a Mochi pairing code. On your Mac: Settings › iPhone › Mochi Link › Pair Your iPhone."
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
        if paired, MochiLink.relay?.removed == true {
            // The Mac unpaired (deleting the room) or removed this phone: the old pairing can't work again.
            let mac = credentials?.peerName ?? "Your Mac"
            forget()
            problem = "\(mac) unpaired this iPhone. Scan a new code to pair again."
            MacLink.shared.log("link: removed by the relay; forgot the pairing")
        }
        status = MochiLink.relay?.status ?? .offline
        peers = MochiLink.relay?.peers ?? []
    }
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
                    Tag(text: link.macOnline ? "Mac online" : link.status == .online ? "Mac away" : "Connecting",
                        symbol: link.macOnline ? "checkmark" : "moon.zzz.fill",
                        tint: link.macOnline ? Theme.success : Theme.inkSecondary)
                }
            }
            if link.paired {
                Label("Paired with \(link.macName)", systemImage: "link")
                    .font(.mochi(.subheadline)).foregroundStyle(Theme.ink)
                Text(link.macOnline
                     ? "Messages reach your Mac in under a second, end-to-end encrypted."
                     : "Your Mac isn't connected right now (asleep or off). What you send waits for it for 10 minutes.")
                    .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
                Button("Unpair", role: .destructive) { confirmUnpair = true }
                    .font(.mochi(.footnote))
            } else {
                Text("Not paired yet, so Mochi lives here on its own. Pair once to bring in your Mac: the room follows it, what you "
                     + "say reaches it in under a second, and Claude's summaries and the Live Activity arrive here, end-to-end "
                     + "encrypted. On your Mac: Settings › iPhone › Mochi Link › Pair Your iPhone, then scan the code.")
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
        .confirmationDialog("Unpair from \(link.macName)?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { link.unpair() }
        } message: {
            Text("Mochi Pocket stops hearing from your Mac until you scan a new code.")
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
