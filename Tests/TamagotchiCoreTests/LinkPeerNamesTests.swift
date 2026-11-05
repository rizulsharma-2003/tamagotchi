import Foundation
import Testing
@testable import TamagotchiCore

/// The names every screen uses for the devices in a Mochi Link room (`LinkPeerNames`; Flutter has the same rules
/// and the same cases in mochi_link's link_names_test.dart).
@Suite("Mochi Link names")
struct LinkPeerNamesTests {
    private typealias Peer = RelayLinkStore.Peer

    private let me = "dev_phone"
    private let phone = Peer(device: "dev_phone", role: "pocket", name: "iPhone", platform: "iOS", online: true, lastSeen: 1_793_800_100)
    private let mac = Peer(device: "dev_mac", role: "host", name: "BELPL-LT-636", platform: "macOS", online: true, lastSeen: 1_793_800_000)
    private let pc = Peer(device: "dev_pc", role: "host", name: "DESKTOP-7", platform: "windows", online: false, lastSeen: 1_793_799_000)
    private let android = Peer(device: "dev_android", role: "pocket", name: "realme RMX3242", platform: "android", online: true)
    private let cloud = Peer(device: "dev_cloud", role: "cloud", name: "Mochi Cloud", platform: "cloud", lastSeen: 1_793_790_000)

    @Test func platformTagsInAnyCase() {
        #expect(LinkPlatform(tag: "macOS") == .macOS && LinkPlatform(tag: "macos") == .macOS)
        #expect(LinkPlatform(tag: "Windows") == .windows && LinkPlatform(tag: "iOS") == .iOS)
        #expect(LinkPlatform(tag: "android") == .android && LinkPlatform(tag: "cloud") == .cloud)
        #expect(LinkPlatform(tag: nil) == nil && LinkPlatform(tag: "linux") == nil)
    }

    @Test func macHost() {
        let host = LinkPeerNames.host(in: [phone, mac, cloud], excluding: me, pairedName: "BELPL-LT-636")
        #expect(host.platform == .macOS && host.online)
        #expect(host.yours == "your Mac" && host.yoursCapitalized == "Your Mac")
        #expect(host.labeled == "BELPL-LT-636 (Mac)")
        #expect(host.onlineText == "Mac online" && host.awayText(since: "2:02 PM") == "Mac away since 2:02 PM")
    }

    @Test func pcHost() {
        let host = LinkPeerNames.host(in: [phone, pc], excluding: me)
        #expect(host.yours == "your PC" && host.short == "PC" && host.labeled == "DESKTOP-7 (PC)")
        #expect(!host.online && host.awayText(since: nil) == "PC away")
        #expect(host.lastSeen == Date(timeIntervalSince1970: 1_793_799_000))
    }

    @Test func twoHostsPreferTheOnlineOneThenTheLatest() {
        #expect(LinkPeerNames.host(in: [pc, mac, phone], excluding: me).platform == .macOS)
        var asleep = mac
        asleep.online = false
        // Both away: the one seen last (the Mac, 1000 s after the PC).
        #expect(LinkPeerNames.host(in: [pc, asleep], excluding: me).platform == .macOS)
        asleep.lastSeen = 1_793_000_000
        #expect(LinkPeerNames.host(in: [asleep, pc], excluding: me).platform == .windows)
        #expect(LinkPeerNames.hostList(in: [phone, mac, pc], excluding: me) == "BELPL-LT-636 (Mac) and DESKTOP-7 (PC)")
    }

    @Test func unknownPlatformFallsBackToThePairingName() {
        let old = Peer(device: "dev_mac", role: "host", name: nil, online: true)
        let host = LinkPeerNames.host(in: [old], excluding: me, pairedName: "BELPL-LT-636")
        #expect(host.platform == nil && host.yours == "BELPL-LT-636" && host.yoursCapitalized == "BELPL-LT-636")
        #expect(host.labeled == "BELPL-LT-636" && host.onlineText == "Computer online")
        // No device list yet: the pairing name, or the platform last seen for this room.
        #expect(LinkPeerNames.host(in: [], pairedName: "BELPL-LT-636").yours == "BELPL-LT-636")
        #expect(LinkPeerNames.host(in: [], pairedName: "BELPL-LT-636", knownPlatform: .macOS).labeled == "BELPL-LT-636 (Mac)")
        // Nothing at all.
        let nothing = LinkPeerNames.host(in: [])
        #expect(nothing.yours == "your computer" && nothing.yoursCapitalized == "Your computer" && nothing.labeled == "your computer")
        #expect(LinkPeerNames.hostList(in: [], pairedName: "BELPL-LT-636") == "BELPL-LT-636")
    }

    @Test func iPhoneAndAndroidPhones() {
        let room = [mac, phone, android, cloud]
        #expect(LinkPeerNames.phones(in: room, excluding: "dev_mac").map(\.device) == ["dev_phone", "dev_android"])
        #expect(LinkPeerNames.row(for: android) == "realme RMX3242 · Android")
        #expect(LinkPeerNames.row(for: phone) == "iPhone · iOS")
        #expect(LinkPeerNames.row(for: pc) == "DESKTOP-7 · Windows")
        #expect(LinkPeerNames.label(for: phone) == "iPhone" && LinkPeerNames.label(for: android) == "Android")
        #expect(LinkPeerNames.label(for: Peer(device: "x", role: "pocket")) == "Phone")
        #expect(LinkPeerNames.row(for: Peer(device: "x", role: "pocket")) == "Phone")
        #expect(LinkPeerNames.hasIPhone(in: room, excluding: "dev_mac"))
        #expect(!LinkPeerNames.hasIPhone(in: [mac, android], excluding: "dev_mac"))
        #expect(LinkPeerNames.phoneNames(in: room, excluding: "dev_mac") == "iPhone and realme RMX3242")
        #expect(LinkPeerNames.phoneNames(in: [mac], excluding: "dev_mac") == "your phones")
        #expect(LinkPeerNames.list(["A", "B", "C"]) == "A, B and C")
    }

    @Test func devicesFramesKeepThePlatform() {
        let devices: [[String: Any]] = [
            ["id": "dev_mac", "role": "host", "platform": "macOS", "name": "BELPL-LT-636", "online": true, "lastSeen": 1_793_800_000],
            ["id": "dev_android", "role": "pocket", "platform": "android", "name": "realme RMX3242", "online": false],
        ]
        var peers = RelayLinkStore.merge([], with: devices, names: true)
        #expect(peers.map(\.platform) == ["macOS", "android"])
        // A presence frame says only who's online; the platform and name stay.
        peers = RelayLinkStore.merge(peers, with: [["device": "dev_mac", "online": false]], names: false)
        #expect(peers.first { $0.device == "dev_mac" } == Peer(device: "dev_mac", role: "host", name: "BELPL-LT-636", platform: "macOS",
                                                                 online: false, lastSeen: 1_793_800_000))
    }
}
