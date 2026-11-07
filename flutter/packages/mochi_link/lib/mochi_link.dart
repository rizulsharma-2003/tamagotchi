/// Mochi Link for the Flutter apps (docs/MOCHI_LINK_PLAN.md): the Dart client of the end-to-end encrypted relay
/// that Mochi's Swift Mac and iPhone apps use, interoperable with them on the wire.
///
/// - [LinkCrypto]: AES-256-GCM with the room key K and the associated data
///   `mochi-link/v1|<room>|<key>|<id>|<from>`, byte-for-byte as `link-spec/vectors.json`; the Live Activity key.
/// - [PairingCode], [LinkCredentials], [LinkPairing]: the QR code, this device's place in a room, and the relay's
///   HTTP calls (create a room, invite, join, remove a device, delete the room).
/// - [RelayLink]: the socket client (Swift `RelayLinkStore`): `hello`/`sync`, sealed `put`/`send`, acks both
///   ways, resending what the relay didn't acknowledge, an outbox while offline, backoff, pings, presence.
/// - [LinkKey], [LinkEnvelope]: the key names and the frame.
/// - Models for every value ([PetLook], [ClaudeMirror], [PhoneSessions], [AgentPending], [AgentDoneList],
///   [LinkCommand], [LinkReply], …), checked against `link-spec/fixtures`.
/// - [LinkAlert]: sealed notifications for the phones (4.6.1), on [RelayLink.alerts] and [RelayLink.sendAlert].
/// - [LinkPeerNames], [LinkHostName], [LinkPlatform]: what every screen calls the devices in the room ("your Mac",
///   "your PC", "realme RMX3242 · Android"), as the Swift apps do.
///
/// - [RelayLink.register]: push addresses for the relay's push gateway (an FCM token on Android).
/// - [LinkPairing.send], [LinkPairing.devices]: one frame (or the device list) over HTTPS, for a device with no socket
///   open, like a phone answering a notification while its app is closed.
///
/// Not here yet (TODO, as the Swift side gets them): `agentNews` and per-device `done.<device>` keys, and key
/// rotation when a device is removed (4.2).
library;

export 'src/link_alert.dart';
export 'src/link_credentials.dart';
export 'src/link_crypto.dart';
export 'src/link_envelope.dart';
export 'src/link_key.dart';
export 'src/link_names.dart';
export 'src/link_pairing.dart';
export 'src/link_socket.dart';
export 'src/models.dart';
export 'src/pairing_code.dart';
export 'src/relay_link.dart';
