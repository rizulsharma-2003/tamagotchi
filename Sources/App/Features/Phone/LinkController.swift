import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import Observation
import TamagotchiCore

/// Mochi Link on the Mac (docs/MOCHI_LINK_PLAN.md): the room this Mac hosts on the relay, the QR code that lets a phone
/// join it, and who's connected. The relay is the only way between this Mac and the phones: unpaired, nothing goes out.
@MainActor
@Observable
final class LinkController {
    /// The relay on the user's Cloudflare account.
    static let relayHost = "mochi-link.spike01.workers.dev"

    private(set) var credentials = LinkController.savedCredentials()
    private(set) var code: PairingCode?
    private(set) var codeExpires: Date?
    private(set) var working = false
    private(set) var problem: String?
    private(set) var status = RelayLinkStore.Status.offline
    private(set) var peers: [RelayLinkStore.Peer] = []

    var paired: Bool { credentials != nil }
    /// The other devices in the room and whether they're connected.
    var devices: [RelayLinkStore.Peer] { peers.filter { $0.device != credentials?.device } }
    /// The phones in the room (iPhone and Android).
    var phones: [RelayLinkStore.Peer] { LinkPeerNames.phones(in: peers, excluding: credentials?.device) }
    /// An iPhone is paired: the Live Activity needs one.
    var hasIPhone: Bool { LinkPeerNames.hasIPhone(in: peers, excluding: credentials?.device) }
    /// The phones by name ("iPhone and realme RMX3242"), or "your phones".
    var phoneNames: String { LinkPeerNames.phoneNames(in: peers, excluding: credentials?.device) }

    private static func savedCredentials() -> LinkCredentials? {
        #if DEBUG
        if let demo = Demo.room { return demo.credentials }
        #endif
        return LinkCredentialStore.load()
    }

    func start() {
        #if DEBUG
        if let demo = Demo.room {
            // A sample room for screenshots: no relay, nothing written.
            status = .online
            peers = demo.peers
            if Demo.showsCode { Task { await showCode() } }
            return
        }
        #endif
        MochiLink.use(credentials)
        NotificationCenter.default.addObserver(forName: .linkPresenceDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MochiLink.relay?.reconnectNow()
        }
        refresh()
    }

    /// Shows a fresh pairing code, making the room first if this Mac doesn't have one yet.
    func showCode() async {
        #if DEBUG
        if let demo = Demo.room {
            code = PairingCode(relay: demo.credentials.relay, room: demo.credentials.room, invite: "demo", key: demo.credentials.key,
                               name: Self.macName)
            codeExpires = Date().addingTimeInterval(10 * 60)
            return
        }
        #endif
        working = true
        problem = nil
        defer { working = false }
        do {
            var credentials = self.credentials
            if credentials == nil {
                let made = try await LinkPairing.createRoom(relay: Self.relayHost, platform: "macOS", name: Self.macName)
                guard LinkCredentialStore.save(made) else { throw LinkPairing.Problem(message: "Couldn't save the link in the Keychain.") }
                credentials = made
                self.credentials = made
                MochiLink.use(made)
            }
            guard let credentials else { return }
            code = try await LinkPairing.invite(credentials, hostName: Self.macName)
            codeExpires = Date().addingTimeInterval(10 * 60)
        } catch {
            problem = error.localizedDescription
        }
    }

    func hideCode() {
        code = nil
        codeExpires = nil
    }

    /// Deletes this Mac's room on the relay (every device in it, the cloud included, is cut off and its credentials stop
    /// working) and forgets it here. The phones have to pair again; until then nothing reaches them.
    func unpair() {
        #if DEBUG
        if Demo.room != nil { return }
        #endif
        if let credentials {
            Task { try? await LinkPairing.deleteRoom(credentials) }
        }
        LinkCredentialStore.delete()
        credentials = nil
        hideCode()
        MochiLink.use(nil)
        refresh()
    }

    func copyCode() {
        guard let code else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.url.absoluteString, forType: .string)
    }

    private func refresh() {
        #if DEBUG
        if Demo.room != nil { return }
        #endif
        status = MochiLink.relay?.status ?? .offline
        peers = MochiLink.relay?.peers ?? []
        // A phone that joined makes the code used up.
        if code != nil, devices.contains(where: { $0.role == "pocket" && $0.online }) { hideCode() }
    }

    static var macName: String { Host.current().localizedName ?? "Mac" }

    /// The pairing code as a crisp QR image.
    static func qrImage(_ text: String, size: CGFloat = 220) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

#if DEBUG
extension LinkController {
    /// `MACTAMAGOTCHI_DEMO_LINK=phones|android[-code]` with `MACTAMAGOTCHI_DEBUG_STATE=1` (Settings screenshots): this
    /// Mac in a sample room, with an Android phone and an iPhone, or only the Android phone; `-code` also shows a
    /// pairing code. No Keychain, no relay.
    @MainActor
    enum Demo {
        static var showsCode: Bool { ProcessInfo.processInfo.environment["MACTAMAGOTCHI_DEMO_LINK"]?.hasSuffix("-code") == true }

        static var room: (credentials: LinkCredentials, peers: [RelayLinkStore.Peer])? {
            guard DebugHooks.isEnabled, let kind = ProcessInfo.processInfo.environment["MACTAMAGOTCHI_DEMO_LINK"] else { return nil }
            let credentials = LinkCredentials(relay: "demo.invalid", room: "demo", device: "dev_mac", secret: "demo",
                                              key: LinkCrypto.base64url(Data(repeating: 7, count: 32)), role: "host")
            let now = Date().timeIntervalSince1970
            var peers = [
                RelayLinkStore.Peer(device: "dev_mac", role: "host", name: LinkController.macName, platform: "macOS", online: true, lastSeen: now),
                RelayLinkStore.Peer(device: "dev_android", role: "pocket", name: "realme RMX3242", platform: "android", online: true,
                                    lastSeen: now),
            ]
            if !kind.hasPrefix("android") {
                peers.append(.init(device: "dev_iphone", role: "pocket", name: "iPhone", platform: "iOS", online: false, lastSeen: now - 1800))
            }
            peers.append(.init(device: "dev_cloud", role: "cloud", name: "Mochi Cloud", platform: "cloud", lastSeen: now - 3600))
            return (credentials, peers)
        }
    }
}
#endif
