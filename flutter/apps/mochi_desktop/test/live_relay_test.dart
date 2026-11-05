// Against the real relay, opt-in:
//
//   MOCHI_LINK_LIVE=mochi-link.spike01.workers.dev flutter test test/live_relay_test.dart
//
// The desktop app's own Link host (LinkHost + PhoneSync, the real RelayLink and relay API) makes a throwaway room as a
// `host`, a Dart client joins it as a phone would (scanning the QR code), and they exchange what the iPhone and Android
// apps use: the shared state, a command and its replies, a sealed alert. Then Unpair deletes the room, and the phone
// sees it gone. It never touches another room and never prints credentials.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/hook_setup.dart';
import 'package:mochi_desktop/src/core/session_store.dart';
import 'package:mochi_desktop/src/desktop.dart';
import 'package:mochi_desktop/src/link/link_host.dart';
import 'package:mochi_desktop/src/platform/credential_vault.dart';
import 'package:mochi_desktop/src/platform/system.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_wire/mochi_wire.dart';

import 'support/fakes.dart';

void main() {
  final relay = Platform.environment['MOCHI_LINK_LIVE'];

  Future<void> waitFor(bool Function() condition, String what, {Duration timeout = const Duration(seconds: 20)}) async {
    final end = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test(
    'a Windows host room on the real relay: pair a phone, share state, answer a command, send a sealed alert, unpair',
    () async {
      final timings = <String, int>{};
      final watch = Stopwatch()..start();
      int lap() {
        final ms = watch.elapsedMilliseconds;
        watch.reset();
        return ms;
      }

      final temp = Directory.systemTemp.createTempSync('mochi_desktop_live');
      addTearDown(() => temp.deleteSync(recursive: true));
      final paths = BridgePaths('${temp.path}/mochi', windows: false);
      final vault = MemoryVault();
      final claude = FakeClaude(output: FakeClaude.result('{"done": "Fixed the flaky test; all green."}'));
      final desktop = MochiDesktop(
        paths: paths,
        settings: DesktopSettings(MemorySettingsDocument({'shareSummaries': true})),
        sessions: SessionStore(),
        hooks: HookSetup(
          paths: paths,
          settingsFile: '${temp.path}/claude/settings.json',
          style: HookCommandStyle.shell,
          bundledHelper: null,
        ),
        link: LinkHost(
          vault: vault,
          api: const RelayLinkApi(),
          connect: (credentials) => RelayLink(credentials, platform: 'windows', app: 'live-test'),
          relay: relay!,
          hostName: 'Mochi live test PC (temporary)',
          platform: 'windows',
        ),
        motion: SystemMotion(read: () => false),
        claude: () => claude,
      );
      RelayLink? phone;
      var deleted = false;
      addTearDown(() async {
        await phone?.dispose();
        // Whatever happened, the throwaway room goes.
        final credentials = vault.saved ?? desktop.link.credentials;
        if (!deleted && credentials != null) await LinkPairing.deleteRoom(credentials).catchError((Object _) {});
        await desktop.dispose();
      });

      await desktop.start();
      await desktop.link.showCode();
      timings['create room + invite'] = lap();
      expect(desktop.link.problem, isNull);
      final code = PairingCode.parse(desktop.link.code!.url)!;
      expect(code.name, 'Mochi live test PC (temporary)');
      expect(vault.saved!.role, 'host');

      final joined = await LinkPairing.join(code, role: 'pocket', platform: 'android', name: 'Live test phone');
      timings['join'] = lap();
      phone = RelayLink(joined, platform: 'android', app: 'live-test');
      final replies = <LinkReply>[];
      final alerts = <LinkAlert>[];
      phone.incoming.listen((message) {
        if (message.key == LinkKey.reply) replies.add(LinkReply.fromValue(message.value)!);
      });
      phone.alerts.listen(alerts.add);
      phone.start();

      // The phone gets the host's state, in the shapes the phone apps decode.
      await waitFor(
        () => phone!.value(LinkKey.look) != null && phone.value(LinkKey.sessions) != null && phone.value(LinkKey.claude) != null,
        'state',
      );
      timings['state on the phone'] = lap();
      expect(PetLook.fromValue(phone.value(LinkKey.look))!.petName, 'Mochi');
      expect(ClaudeMirror.fromValue(phone.value(LinkKey.claude))!.phase, 'none');
      expect(PhoneSessions.fromValue(phone.value(LinkKey.sessions))!.enabled, isTrue);

      // Each sees the other; the phone used up the code.
      await waitFor(() => desktop.link.devices.any((peer) => peer.device == joined.device && peer.online), 'presence on the host');
      expect(desktop.link.code, isNull);
      expect(phone.peers.where((peer) => peer.role == 'host').single.platform, 'windows');

      // A command from the phone: working, then Mochi's answer.
      phone.set(
        LinkCommand(id: RelayLink.newId(), text: 'status', at: DateTime.now().millisecondsSinceEpoch / 1000, typed: true).toValue(),
        LinkKey.command,
      );
      await waitFor(() => replies.any((reply) => reply.state == 'done'), 'the reply');
      timings['command → reply'] = lap();
      expect(replies.first.state, 'working');
      expect(replies.last.text, 'No Claude sessions right now.');

      // Claude finishes a turn on the PC: the phone gets a sealed alert and the session card.
      for (final event in [
        hook('UserPromptSubmit', session: 'live-s'),
        hook('Stop', session: 'live-s', summary: 'The flaky test is fixed.'),
      ]) {
        expect(await BridgeClient.send(event.encodeLine(), paths.bridgeFile), isA<BridgeAccepted>());
      }
      await waitFor(() => alerts.isNotEmpty, 'the alert');
      timings['turn finished → alert'] = lap();
      expect(alerts.single.title, 'web');
      expect(alerts.single.subtitle, 'Claude finished');
      expect(alerts.single.body, 'Fixed the flaky test; all green.');
      await waitFor(() => PhoneSessions.fromValue(phone!.value(LinkKey.sessions))!.sessions.isNotEmpty, 'the session card');
      expect(PhoneSessions.fromValue(phone.value(LinkKey.sessions))!.sessions.single.summary!.done, 'Fixed the flaky test; all green.');

      // Unpair: the room is deleted and the phone is told.
      await desktop.link.unpair();
      deleted = true;
      timings['unpair'] = lap();
      expect(vault.saved, isNull);
      await waitFor(() => phone!.status == LinkStatus.removed, 'the phone to see the room gone');
      timings['phone sees removal'] = lap();
      // ignore: avoid_print
      print('live relay timings (ms): $timings');
    },
    skip: relay == null ? 'set MOCHI_LINK_LIVE=<relay host> to run against a real relay' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
