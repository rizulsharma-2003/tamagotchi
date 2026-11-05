// Against a real relay, opt-in:
//
//   MOCHI_LINK_LIVE=mochi-link.spike01.workers.dev dart test test/live_test.dart
//
// Makes its own throwaway room (never touches another), pairs two Dart clients through it, and deletes it at the
// end. Prints the latencies it measured; never prints credentials.

import 'dart:async';
import 'dart:io';

import 'package:mochi_link/mochi_link.dart';
import 'package:test/test.dart';

void main() {
  final relay = Platform.environment['MOCHI_LINK_LIVE'];

  Future<void> waitFor(bool Function() condition, String what, {Duration timeout = const Duration(seconds: 15)}) async {
    final end = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Runs [act] and waits for the first [stream] event matching [test]; the elapsed time in ms.
  Future<int> timed<T>(Stream<T> stream, bool Function(T) test, void Function() act) async {
    final watch = Stopwatch()..start();
    final arrived = stream.firstWhere(test).timeout(const Duration(seconds: 15));
    act();
    await arrived;
    return watch.elapsedMilliseconds;
  }

  double now() => DateTime.now().millisecondsSinceEpoch / 1000;

  test(
    'two Dart clients pair through a fresh room, exchange sealed commands, replies and state, see each other, '
    'and get what was sent while away',
    () async {
      final timings = <String, int>{};
      final logs = <String>[];
      final watch = Stopwatch()..start();
      int lap() {
        final ms = watch.elapsedMilliseconds;
        watch.reset();
        return ms;
      }

      final health = await LinkPairing.health(relay!);
      timings['health'] = lap();
      expect(health['ok'], true);
      expect(health['protocol'], 1);

      final hostCredentials = await LinkPairing.createRoom(relay: relay, platform: 'windows', name: 'mochi_link test PC');
      timings['create room'] = lap();
      var deleted = false;
      addTearDown(() async {
        if (!deleted) await LinkPairing.deleteRoom(hostCredentials).catchError((Object _) {});
      });
      expect(hostCredentials.role, 'host');
      expect(hostCredentials.roomKey, hasLength(32));

      final code = await LinkPairing.invite(hostCredentials, hostName: 'Test PC', role: 'pocket');
      timings['invite'] = lap();
      final scanned = PairingCode.parse(code.url)!;
      expect(scanned, code);
      final phoneCredentials = await LinkPairing.join(scanned, role: 'pocket', platform: 'android', name: 'Test Android');
      timings['join'] = lap();
      expect(phoneCredentials.key, hostCredentials.key);
      expect(phoneCredentials.peerName, 'Test PC');
      expect(phoneCredentials.role, 'pocket');
      // The invite works once.
      await expectLater(
        LinkPairing.join(code, role: 'pocket', platform: 'android', name: 'Again'),
        throwsA(isA<LinkPairingException>().having((error) => error.code, 'code', 'invite_used')),
      );

      final clients = <RelayLink>[];
      addTearDown(() => Future.wait(clients.map((client) => client.dispose())));
      RelayLink client(LinkCredentials credentials, String platform) {
        final link = RelayLink(
          credentials,
          platform: platform,
          app: 'mochi_link-test',
          onLog: (message) => logs.add('${credentials.role}: $message'),
        );
        clients.add(link);
        return link;
      }

      final host = client(hostCredentials, 'windows');
      final phone = client(phoneCredentials, 'android');
      lap();
      host.start();
      phone.start();
      await waitFor(() => host.status == LinkStatus.online && phone.status == LinkStatus.online, 'both online');
      timings['connect'] = lap();
      await waitFor(
        () => phone.onlinePeers.any((peer) => peer.role == 'host') && host.onlinePeers.any((peer) => peer.role == 'pocket'),
        'presence on both sides',
      );
      timings['presence'] = lap();
      // The app version each said in its hello shows in the device list.
      host.requestDevices();
      await waitFor(() => host.peers.any((peer) => peer.device == phoneCredentials.device && peer.app != null), 'the device list');
      final seenByHost = host.peers.firstWhere((peer) => peer.device == phoneCredentials.device);
      expect([seenByHost.name, seenByHost.platform, seenByHost.app], ['Test Android', 'android', 'mochi_link-test']);

      // Phone → host: a command.
      timings['command'] = await timed(
        host.incoming,
        (item) => item.key == LinkKey.command,
        () => phone.set(LinkCommand(id: 'cmd-live', text: 'hi', at: now(), typed: true).toValue(), LinkKey.command),
      );
      final command = LinkCommand.fromValue(host.value(LinkKey.command))!;
      expect([command.id, command.text, command.typed], ['cmd-live', 'hi', true]);
      expect(host.onlinePeers.single.device, phoneCredentials.device);

      // Host → phone: the reply.
      timings['reply'] = await timed(
        phone.incoming,
        (item) => item.key == LinkKey.reply,
        () => host.set(LinkReply(id: 'cmd-live', state: 'done', text: 'Hello!', at: now()).toValue(), LinkKey.reply),
      );
      expect(LinkReply.fromValue(phone.value(LinkKey.reply))?.text, 'Hello!');

      // State, and clearing it.
      const look = PetLook(petName: 'Mochi', companionName: 'Patch', petColor: 'mint', theme: 'cozyDesk', friendshipLevel: 2);
      timings['state put'] = await timed(
        phone.changes,
        (keys) => keys.contains(LinkKey.look),
        () => host.set(look.toValue(), LinkKey.look),
      );
      expect(PetLook.fromValue(phone.value(LinkKey.look))?.petColor, 'mint');
      host.set(
        const ApprovalRequest(id: 'ap-1', target: 'session-1', message: 'Run the tests?', at: 1762243200).toValue(),
        LinkKey.approval,
      );
      await waitFor(() => phone.map(LinkKey.approval)?['id'] == 'ap-1', 'the approval');
      host.set(null, LinkKey.approval);
      await waitFor(() => phone.value(LinkKey.approval) == null, 'the approval cleared');
      phone.set(const AgentDoneList(ids: {'mail:1': 1762243150}).toValue(), LinkKey.phoneDone);
      await waitFor(() => AgentDoneList.fromValue(host.value(LinkKey.phoneDone))?.ids['mail:1'] != null, 'phoneDone');

      // A command sent while the host is away waits for it.
      lap();
      await host.stop();
      await waitFor(() => !phone.onlinePeers.any((peer) => peer.role == 'host'), 'the host going offline');
      timings['offline seen'] = lap();
      phone.set(LinkCommand(id: 'cmd-queued', text: 'while away', at: now()).toValue(), LinkKey.command);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final laterHost = client(hostCredentials, 'windows');
      timings['queued (start → delivered)'] = await timed(
        laterHost.incoming,
        (item) => item.key == LinkKey.command && LinkCommand.fromValue(item.value)?.id == 'cmd-queued',
        laterHost.start,
      );
      expect(LinkCommand.fromValue(laterHost.value(LinkKey.command))?.text, 'while away');
      // Its own state comes back after a restart, and the phone's.
      await waitFor(() => laterHost.value(LinkKey.look) != null, 'own state after a restart');
      expect(PetLook.fromValue(laterHost.value(LinkKey.look))?.petName, 'Mochi');
      expect(laterHost.value(LinkKey.approval), isNull);
      expect(AgentDoneList.fromValue(laterHost.value(LinkKey.phoneDone))?.ids.keys, ['mail:1']);
      await waitFor(() => phone.onlinePeers.any((peer) => peer.role == 'host'), 'the host back online');

      // Removing the phone ends its link; deleting the room ends the host's.
      await LinkPairing.remove(phoneCredentials.device, from: hostCredentials);
      await waitFor(() => phone.status == LinkStatus.removed, 'the phone removed (4001)');
      await waitFor(() => laterHost.peers.every((peer) => peer.device != phoneCredentials.device), 'the phone gone from devices');
      lap();
      await LinkPairing.deleteRoom(hostCredentials);
      deleted = true;
      timings['delete room'] = lap();
      await waitFor(() => laterHost.status == LinkStatus.removed, 'the host removed (4004)');
      await expectLater(LinkPairing.invite(hostCredentials, hostName: 'x'), throwsA(isA<LinkPairingException>()));

      printOnFailure(logs.join('\n'));
      // ignore: avoid_print
      print('live relay ($relay): ${timings.entries.map((entry) => '${entry.key} ${entry.value} ms').join(', ')}');
    },
    skip: relay == null ? 'set MOCHI_LINK_LIVE=<relay host> to run against a real relay' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
