// Notification buttons against a real relay, in a throwaway room of their own (never anyone's real room):
//
//   MOCHI_LINK_LIVE=mochi-link.spike01.workers.dev flutter test test/live_actions_test.dart
//
// A stand-in computer holds the room's socket, as the Mac does; a phone's Reply and Mark done go over HTTPS, as they
// do from the background isolate with the app closed. The room is deleted at the end. Skipped without the variable.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/model/done_marks.dart';
import 'package:mochi_pocket/src/services/credential_store.dart';
import 'package:mochi_pocket/src/services/local_file.dart';
import 'package:mochi_pocket/src/services/notify/action_dispatcher.dart';
import 'package:mochi_pocket/src/services/notify/action_outbox.dart';
import 'package:mochi_pocket/src/services/notify/background_actions.dart';
import 'package:mochi_pocket/src/services/notify/notification_plan.dart';

void main() {
  final relay = Platform.environment['MOCHI_LINK_LIVE'];

  test(
    'Reply and Mark done reach the computer over HTTPS, and the confirmation names it',
    () async {
      final host = await LinkPairing.createRoom(relay: relay!, platform: 'macOS', name: 'Live action test');
      final link = RelayLink(host, platform: 'macOS', app: 'live-test');
      try {
        final code = await LinkPairing.invite(host, hostName: 'Live action test', role: 'pocket');
        final phone = await LinkPairing.join(code, role: 'pocket', platform: 'android', name: 'Live test phone');
        final commands = <LinkCommand>[];
        final doneLists = <AgentDoneList>[];
        link.incoming.listen((message) {
          if (message.key == LinkKey.command) commands.add(LinkCommand.fromValue(message.value)!);
          if (message.key == LinkKey.phoneDone) doneLists.add(AgentDoneList.fromValue(message.value)!);
        });
        final online = link.presence.firstWhere((presence) => presence.status == LinkStatus.online);
        link.start();
        await online.timeout(const Duration(seconds: 20));

        final done = MemoryDocument();
        final outbox = MemoryDocument();
        final receipts = <ActionReceipt>[];
        final dispatcher = ActionDispatcher(
          state: FileActionState(credentials: MemoryCredentialStore(phone), done: done, outbox: outbox, host: MemoryDocument()),
          relay: const HttpRelayPost(),
          receipt: (receipt) async => receipts.add(receipt),
        );
        final watch = Stopwatch()..start();
        final replied = await dispatcher.run(
          NotificationAction(
            notificationId: 1,
            action: AlertAction.reply,
            input: 'Run the tests',
            payload: NotificationPayload(
              alert: 'a1',
              room: phone.room,
              title: 'mac-Tamagotchi',
              project: 'mac-Tamagotchi',
              session: 'session-1',
            ),
          ),
        );
        expect(replied, ActionResult.sent);
        final marked = await dispatcher.run(
          NotificationAction(
            notificationId: 2,
            action: AlertAction.markDone,
            payload: NotificationPayload(alert: 'a2', room: phone.room, ids: const ['mail:live'], names: const ['Priya Sharma']),
          ),
        );
        expect(marked, ActionResult.sent);
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while ((commands.isEmpty || doneLists.isEmpty) && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        // ignore: avoid_print
        print('both actions reached the computer ${watch.elapsedMilliseconds} ms after the first press');
        expect((commands.single.text, commands.single.project, commands.single.session), ('Run the tests', 'mac-Tamagotchi', 'session-1'));
        expect(doneLists.last.ids.keys, ['mail:live']);
        expect(NotificationOutbox.fromJson(outbox.json).sent.single.id, commands.single.id);
        expect(DoneMarks.fromJson(done.json).doneBy('mail:live'), DoneMarks.here);
        expect(receipts.map((receipt) => receipt.body), [
          'Sent to Claude in mac-Tamagotchi on your Mac: “Run the tests”',
          'Priya Sharma. Done on your Mac and your other phones too.',
        ]);
      } finally {
        await link.dispose();
        await LinkPairing.deleteRoom(host);
      }
    },
    skip: relay == null ? 'set MOCHI_LINK_LIVE=<relay host> to run against a real relay' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
