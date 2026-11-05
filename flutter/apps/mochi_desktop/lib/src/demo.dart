// Development only (`MOCHI_DESKTOP_DEMO=1`): Mochi Link without the network, for screenshots and trying the screens.
// The room, the pairing code and its key are made up and never reach a relay; two phones appear in the room.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mochi_link/mochi_link.dart';

import 'link/link_host.dart';

bool get demoMode => Platform.environment['MOCHI_DESKTOP_DEMO'] == '1';

class DemoLinkApi implements LinkApi {
  const DemoLinkApi();

  @override
  Future<LinkCredentials> createRoom({required String relay, required String platform, required String name}) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return LinkCredentials(
      relay: 'demo.invalid',
      room: 'room_demo',
      device: 'dev_this_pc',
      secret: 'demo',
      key: LinkCrypto.base64url(LinkCrypto.newRoomKey()),
      role: 'host',
    );
  }

  @override
  Future<PairingCode> invite(LinkCredentials credentials, {required String hostName}) async => PairingCode(
    relay: credentials.relay,
    room: credentials.room,
    invite: 'demo-invite-${DateTime.now().millisecondsSinceEpoch}',
    key: credentials.key,
    name: hostName,
  );

  @override
  Future<void> deleteRoom(LinkCredentials credentials) async {}
}

/// A pretend relay: answers `hello` with a room holding this PC and two phones, and acknowledges everything.
class DemoSocket implements LinkSocket {
  DemoSocket(this.device);

  final String device;
  final StreamController<Object?> _frames = StreamController();

  @override
  Future<void> get ready => Future.value();

  @override
  Stream<Object?> get stream => _frames.stream;

  @override
  void send(String text) {
    final frame = jsonDecode(text) as Map;
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    if (frame['op'] == 'hello') {
      _frames.add(
        jsonEncode({
          'v': 1,
          'op': 'sync',
          'state': <Object?>[],
          'queue': <Object?>[],
          'minClientVersion': 1,
          'devices': [
            {'id': device, 'role': 'host', 'platform': 'windows', 'name': 'This PC', 'online': true},
            {'id': 'dev_iphone', 'role': 'pocket', 'platform': 'ios', 'name': "Rizul's iPhone", 'app': '1.4', 'online': true},
            {
              'id': 'dev_pixel',
              'role': 'pocket',
              'platform': 'android',
              'name': 'Pixel 8',
              'app': '0.1.0',
              'online': false,
              'lastSeen': now - 1500,
            },
          ],
        }),
      );
    } else if (frame['id'] is String && (frame['op'] == 'put' || frame['op'] == 'send')) {
      _frames.add(jsonEncode({'v': 1, 'op': 'ack', 'id': frame['id']}));
    }
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_frames.isClosed) await _frames.close();
  }

  @override
  int? get closeCode => null;
}
