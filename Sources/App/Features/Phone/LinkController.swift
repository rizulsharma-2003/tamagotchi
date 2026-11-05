import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import Observation
import TamagotchiCore

/// Mochi Link on the Mac (docs/MOCHI_LINK_PLAN.md): the room this Mac hosts on the relay, the QR code that lets a phone
/// join it, and who's connected. Once paired, the Mac and iPhone talk through the relay (iCloud stays on as a backup).
@MainActor
@Observable
final class LinkController {
    /// The relay on the user's Cloudflare account.
    static let relayHost = "mochi-link.spike01.workers.dev"

    private(set) var credentials = LinkCredentialStore.load()
    private(set) var code: PairingCode?
    private(set) var codeExpires: Date?
    private(set) var working = false
    private(set) var problem: String?
    private(set) var status = RelayLinkStore.Status.offline
    private(set) var peers: [RelayLinkStore.Peer] = []

    var paired: Bool { credentials != nil }
    /// The other devices in the room and whether they're connected.
    var devices: [RelayLinkStore.Peer] { peers.filter { $0.device != credentials?.device } }

    func start() {
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
    /// working) and forgets it here. The phone has to pair again; iCloud carries on as before.
    func unpair() {
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
