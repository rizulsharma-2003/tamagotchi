import 'relay_link.dart';

/// What a device in a Mochi Link room is, from the relay's `platform` tag. Tags come in any case: the Mac says
/// `macOS`, the iPhone `iOS`, Android `android`, Windows `windows`, Mochi Cloud `cloud` (Swift `LinkPlatform`).
enum LinkPlatform {
  macOS('Mac', 'macOS'),
  windows('PC', 'Windows'),
  iOS('iPhone', 'iOS'),
  android('Android', 'Android'),
  cloud('Mochi Cloud', 'Cloud');

  const LinkPlatform(this.label, this.systemName);

  /// What people call the device: "Mac", "PC", "iPhone", "Android", "Mochi Cloud".
  final String label;

  /// Its system, for device lists: "macOS", "Windows", "iOS", "Android", "Cloud".
  final String systemName;

  bool get isComputer => this == macOS || this == windows;
  bool get isPhone => this == iOS || this == android;

  /// Null for a missing or unknown tag (older relay data).
  static LinkPlatform? parse(String? tag) => switch (tag?.trim().toLowerCase()) {
    'macos' || 'mac' || 'osx' || 'darwin' => macOS,
    'windows' || 'win32' || 'win' => windows,
    'ios' || 'ipados' || 'iphone' => iOS,
    'android' => android,
    'cloud' => cloud,
    _ => null,
  };
}

/// Names for one device in the room.
extension LinkPeerPlatform on LinkPeer {
  LinkPlatform? get linkPlatform => LinkPlatform.parse(platform);

  /// When it was last seen (the relay counts seconds; very large numbers are taken as milliseconds).
  DateTime? get lastSeenTime => _time(lastSeen);
}

DateTime? _time(double? seconds) =>
    seconds == null ? null : DateTime.fromMillisecondsSinceEpoch((seconds > 10000000000 ? seconds : seconds * 1000).round());

String? _clean(String? name) => name == null || name.trim().isEmpty ? null : name;

/// The computer a phone talks to, named for the phone's screens: "your Mac", "your PC", or (when the relay hasn't
/// said which) the name it had when the phone paired, else "your computer" (Swift `LinkHostName`).
class LinkHostName {
  LinkHostName({LinkPlatform? platform, String? name, this.online = false, this.lastSeen})
    : platform = platform != null && platform.isComputer ? platform : null,
      name = _clean(name);

  /// [LinkPlatform.macOS] or [LinkPlatform.windows]; null when unknown.
  final LinkPlatform? platform;

  /// Its own name ("BELPL-LT-636"), from the relay's device list or the pairing code.
  final String? name;
  final bool online;
  final DateTime? lastSeen;

  /// "Mac" or "PC" (null when unknown).
  String? get kind => platform?.label;

  /// For pills and short labels: "Mac", "PC" or "Computer".
  String get short => kind ?? 'Computer';

  /// "your Mac", "your PC"; when the platform isn't known, its name, else "your computer".
  String get yours => kind != null ? 'your $kind' : name ?? 'your computer';

  /// [yours] at the start of a sentence: "Your Mac", "BELPL-LT-636".
  String get yoursCapitalized => yours.startsWith('your ') ? 'Y${yours.substring(1)}' : yours;

  /// "BELPL-LT-636 (Mac)"; only the name when the platform isn't known; [yours] without a name.
  String get labeled {
    final name = this.name;
    final kind = this.kind;
    if (name == null) return yours;
    if (kind == null || name.toLowerCase() == kind.toLowerCase()) return name;
    return '$name ($kind)';
  }

  /// The status pill while it's connected: "Mac online".
  String get onlineText => '$short online';

  /// The status pill while it isn't: "PC away since 14:02" ([since] is the time, formatted by the screen), "Mac away".
  String awayText({String? since}) => since == null ? '$short away' : '$short away since $since';

  @override
  bool operator ==(Object other) =>
      other is LinkHostName && other.platform == platform && other.name == name && other.online == online && other.lastSeen == lastSeen;

  @override
  int get hashCode => Object.hash(platform, name, online, lastSeen);

  @override
  String toString() => 'LinkHostName($labeled, ${online ? 'online' : 'away'})';
}

/// Names for the devices in a Mochi Link room, the same on every screen: a phone names its computer ("your Mac",
/// "your PC"), a computer names its phones ("your phones", "realme RMX3242 · Android"). The Swift apps have the same
/// rules in TamagotchiCore's `LinkPeerNames`; mochi_desktop (Windows) can use these for its phones.
abstract final class LinkPeerNames {
  /// What a computer calls its phones when it doesn't mean one in particular.
  static const yourPhones = 'your phones';

  // MARK: A phone naming its computer

  /// The room's computers (not [me]), best first: connected ones, then the most recently seen.
  static List<LinkPeer> hosts(Iterable<LinkPeer> peers, {String? me}) {
    final hosts = peers.where((peer) => peer.device != me && (peer.role == 'host' || (peer.linkPlatform?.isComputer ?? false))).toList();
    final order = {for (final (index, peer) in hosts.indexed) peer.device: index};
    hosts.sort((a, b) {
      if (a.online != b.online) return a.online ? -1 : 1;
      final seen = (b.lastSeenTime?.millisecondsSinceEpoch ?? 0).compareTo(a.lastSeenTime?.millisecondsSinceEpoch ?? 0);
      return seen != 0 ? seen : order[a.device]!.compareTo(order[b.device]!);
    });
    return hosts;
  }

  /// The computer a phone names: an online one first, else the one seen most recently. Until the relay's device
  /// list arrives (or when it doesn't say the platform), [pairedName] (the name in the pairing code) and
  /// [knownPlatform] (the platform this phone last saw for its room) fill in.
  static LinkHostName host(Iterable<LinkPeer> peers, {String? me, String? pairedName, LinkPlatform? knownPlatform}) {
    final peer = hosts(peers, me: me).firstOrNull;
    if (peer == null) return LinkHostName(platform: knownPlatform, name: pairedName);
    final platform = peer.linkPlatform;
    return LinkHostName(
      platform: platform != null && platform.isComputer ? platform : knownPlatform,
      name: _clean(peer.name) ?? pairedName,
      online: peer.online,
      lastSeen: peer.lastSeenTime,
    );
  }

  /// Every computer in the room, labeled ("BELPL-LT-636 (Mac) and DESKTOP-7 (PC)"), for "Paired with …". With no
  /// device list yet, the one from the pairing code.
  static String hostList(Iterable<LinkPeer> peers, {String? me, String? pairedName, LinkPlatform? knownPlatform}) {
    final all = hosts(peers, me: me);
    if (all.isEmpty) return host(const [], pairedName: pairedName, knownPlatform: knownPlatform).labeled;
    return list([for (final peer in all) LinkHostName(platform: peer.linkPlatform, name: _clean(peer.name) ?? pairedName).labeled]);
  }

  // MARK: A computer naming its phones

  /// The phones in the room (not [me]), in the relay's order.
  static List<LinkPeer> phones(Iterable<LinkPeer> peers, {String? me}) =>
      peers.where((peer) => peer.device != me && (peer.role == 'pocket' || (peer.linkPlatform?.isPhone ?? false))).toList();

  /// Whether an iPhone is in the room: the Live Activity, Siri and the Lock Screen widget need one.
  static bool hasIPhone(Iterable<LinkPeer> peers, {String? me}) =>
      phones(peers, me: me).any((peer) => peer.linkPlatform == LinkPlatform.iOS);

  /// What a device is: "iPhone", "Android", "Mac", "PC", "Mochi Cloud"; "Phone" or "Computer" by its role when the
  /// platform isn't known.
  static String label(LinkPeer peer) =>
      peer.linkPlatform?.label ??
      switch (peer.role) {
        'pocket' => 'Phone',
        'host' => 'Computer',
        'cloud' => 'Mochi Cloud',
        '' => 'Device',
        final role => '${role[0].toUpperCase()}${role.substring(1)}',
      };

  /// A device list row: its own name and its system, "realme RMX3242 · Android", "iPhone · iOS"; the label alone
  /// when there's nothing more to say.
  static String row(LinkPeer peer) {
    final name = _clean(peer.name) ?? label(peer);
    final system = peer.linkPlatform?.systemName;
    if (system == null || name.toLowerCase() == system.toLowerCase()) return name;
    return '$name · $system';
  }

  /// The phones by name for a sentence ("realme RMX3242 and iPhone"); [yourPhones] when there are none.
  static String phoneNames(Iterable<LinkPeer> peers, {String? me}) {
    final names = [for (final peer in phones(peers, me: me)) _clean(peer.name) ?? label(peer)];
    return names.isEmpty ? yourPhones : list(names);
  }

  /// "A", "A and B", "A, B and C".
  static String list(List<String> items) => switch (items.length) {
    0 => '',
    1 => items.first,
    _ => '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}',
  };
}
