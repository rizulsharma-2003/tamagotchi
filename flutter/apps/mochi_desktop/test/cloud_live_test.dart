// Against the real relay, opt-in (docs/SPRINT_2.md W5):
//
//   MOCHI_LINK_LIVE=mochi-link.spike01.workers.dev flutter test test/cloud_live_test.dart
//
// Copy Cloud Settings for real, in a throwaway room this test makes and deletes: a Windows host room, a phone that
// joins it, then Mochi Cloud joins twice. The second time replaces the first: the room has one Mochi Cloud, the old
// one's credential is refused, the new one's works. It never touches another room and never prints credentials.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/link/link_host.dart';
import 'package:mochi_desktop/src/platform/credential_vault.dart';
import 'package:mochi_link/mochi_link.dart';

void main() {
  final relay = Platform.environment['MOCHI_LINK_LIVE'];

  Future<void> waitFor(bool Function() condition, String what, {Duration timeout = const Duration(seconds: 20)}) async {
    final end = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test(
    'Mochi Cloud joins a Windows host’s room, and joining again replaces it',
    () async {
      const api = RelayLinkApi();
      final host = await api.createRoom(relay: relay!, platform: 'windows', name: 'Mochi W5 live test');
      LinkHost? link;
      try {
        // A phone in the room (the host counts as paired once one is in).
        final code = await api.invite(host, hostName: 'Mochi W5 live test', role: 'pocket');
        await api.join(code, role: 'pocket', platform: 'android', name: 'W5 test phone');
        link = LinkHost(
          vault: MemoryVault(host),
          api: api,
          connect: (credentials) => RelayLink(credentials, platform: 'windows', app: 'w5-live'),
          hostName: 'Mochi W5 live test',
        );
        await link.start();
        await waitFor(() => link!.paired && link.devices.isNotEmpty, 'the phone in the room');

        final watch = Stopwatch()..start();
        final first = await link.joinCloud();
        final firstMs = watch.elapsedMilliseconds;
        expect(first.replaced, isEmpty);
        expect(first.credentials.role, 'cloud');
        var devices = await api.devices(host);
        expect(devices.where((peer) => peer.role == 'cloud').map((peer) => peer.device), [first.credentials.device]);
        expect(devices.firstWhere((peer) => peer.role == 'cloud').name, 'Mochi Cloud');
        // The cloud's own credential works (Mochi Cloud asks for the devices over HTTPS, as mochi_link.py does).
        expect(await api.devices(first.credentials), isNotEmpty);

        watch.reset();
        final second = await link.joinCloud();
        final secondMs = watch.elapsedMilliseconds;
        expect(second.replaced, [first.credentials.device]);
        devices = await api.devices(host);
        expect(devices.where((peer) => peer.role == 'cloud').map((peer) => peer.device), [second.credentials.device]);
        expect(devices.where((peer) => peer.role == 'pocket'), hasLength(1), reason: 'the phone stays');
        // The old Mochi Cloud's settings no longer work; the new ones do.
        final refused = await api.devices(first.credentials).then<Object?>((_) => null, onError: (Object error) => error);
        expect(refused, isA<LinkPairingException>().having((error) => error.status, 'status', anyOf(401, 403, 404)));
        expect(await api.devices(second.credentials), isNotEmpty);
        final block = second.environment(timeZone: 'Asia/Kolkata').split('\n');
        expect(block.map((line) => line.split('=').first), [
          'MOCHI_LINK_RELAY',
          'MOCHI_LINK_ROOM',
          'MOCHI_LINK_DEVICE',
          'MOCHI_LINK_SECRET',
          'MOCHI_LINK_KEY',
          'MOCHI_TIMEZONE',
        ]);
        // ignore: avoid_print
        print('live: Mochi Cloud joined in $firstMs ms; replaced in $secondMs ms; one cloud device in the room');
      } finally {
        link?.dispose();
        await api.deleteRoom(host);
        // ignore: avoid_print
        print('live: throwaway room deleted');
      }
      final gone = await api.devices(host).then<Object?>((_) => null, onError: (Object error) => error);
      expect(gone, isA<LinkPairingException>());
    },
    skip: relay == null ? 'set MOCHI_LINK_LIVE to a relay host to run' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
