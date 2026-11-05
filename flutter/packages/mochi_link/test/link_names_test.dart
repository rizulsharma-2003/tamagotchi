import 'package:mochi_link/mochi_link.dart';
import 'package:test/test.dart';

/// The names every screen uses for the devices in a Mochi Link room, case for case with the Swift
/// `LinkPeerNamesTests` (Tests/TamagotchiCoreTests/LinkPeerNamesTests.swift).
void main() {
  const me = 'dev_phone';
  const phone = LinkPeer(
    device: 'dev_phone',
    role: 'pocket',
    name: 'realme RMX3242',
    platform: 'android',
    online: true,
    lastSeen: 1793800100,
  );
  const mac = LinkPeer(device: 'dev_mac', role: 'host', name: 'BELPL-LT-636', platform: 'macOS', online: true, lastSeen: 1793800000);
  const pc = LinkPeer(device: 'dev_pc', role: 'host', name: 'DESKTOP-7', platform: 'windows', lastSeen: 1793799000);
  const iPhone = LinkPeer(device: 'dev_iphone', role: 'pocket', name: 'iPhone', platform: 'iOS', online: true);
  const cloud = LinkPeer(device: 'dev_cloud', role: 'cloud', name: 'Mochi Cloud', platform: 'cloud', lastSeen: 1793790000);

  LinkPeer copy(LinkPeer peer, {bool? online, double? lastSeen}) => LinkPeer(
    device: peer.device,
    role: peer.role,
    name: peer.name,
    platform: peer.platform,
    online: online ?? peer.online,
    lastSeen: lastSeen ?? peer.lastSeen,
  );

  test('platform tags in any case', () {
    expect(LinkPlatform.parse('macOS'), LinkPlatform.macOS);
    expect(LinkPlatform.parse('macos'), LinkPlatform.macOS);
    expect(LinkPlatform.parse('Windows'), LinkPlatform.windows);
    expect(LinkPlatform.parse('iOS'), LinkPlatform.iOS);
    expect(LinkPlatform.parse('android'), LinkPlatform.android);
    expect(LinkPlatform.parse('cloud'), LinkPlatform.cloud);
    expect(LinkPlatform.parse(null), isNull);
    expect(LinkPlatform.parse('linux'), isNull);
  });

  test('a Mac host', () {
    final host = LinkPeerNames.host([phone, mac, cloud], me: me, pairedName: 'BELPL-LT-636');
    expect(host.platform, LinkPlatform.macOS);
    expect(host.online, isTrue);
    expect(host.yours, 'your Mac');
    expect(host.yoursCapitalized, 'Your Mac');
    expect(host.labeled, 'BELPL-LT-636 (Mac)');
    expect(host.onlineText, 'Mac online');
    expect(host.awayText(since: '14:02'), 'Mac away since 14:02');
  });

  test('a PC host', () {
    final host = LinkPeerNames.host([phone, pc], me: me);
    expect(host.yours, 'your PC');
    expect(host.short, 'PC');
    expect(host.labeled, 'DESKTOP-7 (PC)');
    expect(host.online, isFalse);
    expect(host.awayText(), 'PC away');
    expect(host.lastSeen, DateTime.fromMillisecondsSinceEpoch(1793799000 * 1000));
  });

  test('two hosts: the online one, then the one seen last', () {
    expect(LinkPeerNames.host([pc, mac, phone], me: me).platform, LinkPlatform.macOS);
    final asleep = copy(mac, online: false);
    // Both away: the one seen last (the Mac, 1000 s after the PC).
    expect(LinkPeerNames.host([pc, asleep], me: me).platform, LinkPlatform.macOS);
    expect(LinkPeerNames.host([copy(asleep, lastSeen: 1793000000), pc], me: me).platform, LinkPlatform.windows);
    expect(LinkPeerNames.hostList([phone, mac, pc], me: me), 'BELPL-LT-636 (Mac) and DESKTOP-7 (PC)');
  });

  test('an unknown platform falls back to the pairing name', () {
    const old = LinkPeer(device: 'dev_mac', role: 'host', online: true);
    final host = LinkPeerNames.host([old], me: me, pairedName: 'BELPL-LT-636');
    expect(host.platform, isNull);
    expect(host.yours, 'BELPL-LT-636');
    expect(host.yoursCapitalized, 'BELPL-LT-636');
    expect(host.labeled, 'BELPL-LT-636');
    expect(host.onlineText, 'Computer online');
    // No device list yet: the pairing name, or the platform last seen for this room.
    expect(LinkPeerNames.host(const [], pairedName: 'BELPL-LT-636').yours, 'BELPL-LT-636');
    expect(LinkPeerNames.host(const [], pairedName: 'BELPL-LT-636', knownPlatform: LinkPlatform.macOS).labeled, 'BELPL-LT-636 (Mac)');
    // Nothing at all.
    final nothing = LinkPeerNames.host(const []);
    expect(nothing.yours, 'your computer');
    expect(nothing.yoursCapitalized, 'Your computer');
    expect(nothing.labeled, 'your computer');
    expect(LinkPeerNames.hostList(const [], pairedName: 'BELPL-LT-636'), 'BELPL-LT-636');
  });

  test('iPhone and Android phones', () {
    final room = [mac, iPhone, phone, cloud];
    expect(LinkPeerNames.phones(room, me: 'dev_mac').map((peer) => peer.device), ['dev_iphone', 'dev_phone']);
    expect(LinkPeerNames.row(phone), 'realme RMX3242 · Android');
    expect(LinkPeerNames.row(iPhone), 'iPhone · iOS');
    expect(LinkPeerNames.row(pc), 'DESKTOP-7 · Windows');
    expect(LinkPeerNames.label(iPhone), 'iPhone');
    expect(LinkPeerNames.label(phone), 'Android');
    expect(LinkPeerNames.label(const LinkPeer(device: 'x', role: 'pocket')), 'Phone');
    expect(LinkPeerNames.row(const LinkPeer(device: 'x', role: 'pocket')), 'Phone');
    expect(LinkPeerNames.hasIPhone(room, me: 'dev_mac'), isTrue);
    expect(LinkPeerNames.hasIPhone([mac, phone], me: 'dev_mac'), isFalse);
    expect(LinkPeerNames.phoneNames(room, me: 'dev_mac'), 'iPhone and realme RMX3242');
    expect(LinkPeerNames.phoneNames([mac], me: 'dev_mac'), 'your phones');
    expect(LinkPeerNames.list(['A', 'B', 'C']), 'A, B and C');
  });
}
