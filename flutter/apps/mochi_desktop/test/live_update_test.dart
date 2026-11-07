// Against a real relay, opt-in: the app's own update check, start to finish, the way an installed Mochi does it.
//
//   MOCHI_UPDATE_LIVE=mochi-link.spike01.workers.dev MOCHI_UPDATE_KEY=<the release key's public half> \
//     [MOCHI_UPDATE_CHANNEL=windows-test] flutter test test/live_update_test.dart
//
// (`localhost:8787` works too, with `wrangler dev`.) It makes a throwaway room as a Windows host (the quiet room an
// installed Mochi makes at first launch), asks the relay for the manifest with that room's credential, checks the
// signature against MOCHI_UPDATE_KEY, downloads and checks the zip and unpacks it into a temporary folder, exactly as
// the app would; then it deletes the room. It never installs anything and never prints credentials.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/update/update_feed.dart';
import 'package:mochi_desktop/src/update/update_signing.dart';
import 'package:mochi_desktop/src/update/updater.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_wire/mochi_wire.dart';

void main() {
  final relay = Platform.environment['MOCHI_UPDATE_LIVE'];
  final key = Platform.environment['MOCHI_UPDATE_KEY'];
  final channel = Platform.environment['MOCHI_UPDATE_CHANNEL'] ?? 'windows';

  test(
    'an installed Mochi finds, verifies, downloads and unpacks the release on the relay',
    () async {
      final temp = Directory.systemTemp.createTempSync('mochi_live_update');
      final room = await LinkPairing.createRoom(relay: relay!, platform: 'windows', name: 'Mochi update test');
      try {
        final paths = BridgePaths('${temp.path}/Mochi', windows: false);
        final layout = InstallLayout(installDirectory: '${temp.path}/Programs/Mochi', startMenuDirectory: temp.path, windows: false);
        final told = <ReadyUpdate>[];
        final updater =
            Updater(
                files: UpdateFiles(paths),
                layout: layout,
                installed: true,
                currentVersion: '0.0.1',
                currentBuild: 0,
                feed: RelayUpdateFeed(credentials: () async => room, platform: channel),
                publicKey: UpdateSigning.base64UrlDecode(key!),
                processes: const _NoProcesses(),
                firstCheckAfter: const Duration(days: 1),
              )
              ..onReady = told.add
              ..start();
        addTearDown(updater.dispose);
        final watch = Stopwatch()..start();
        await updater.check();
        expect(updater.phase, UpdatePhase.ready, reason: updater.problem);
        final ready = told.single;
        expect(File('${ready.root}/Mochi.exe').existsSync(), isTrue);
        expect(File('${ready.root}/mochi_hook.exe').existsSync(), isTrue);
        // ignore: avoid_print
        print('Mochi ${ready.version} (build ${ready.build}) from $relay/$channel: verified and unpacked in ${watch.elapsedMilliseconds} ms');
      } finally {
        await LinkPairing.deleteRoom(room);
        temp.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: relay == null || key == null ? 'set MOCHI_UPDATE_LIVE=<relay host> and MOCHI_UPDATE_KEY=<public key> to run' : false,
  );
}

/// Nothing is started: the warm-up of the helper is skipped here.
class _NoProcesses implements ProcessControl {
  const _NoProcesses();

  @override
  bool waitForExit(int pid, Duration timeout) => true;

  @override
  String? executablePath(int pid) => null;

  @override
  bool terminate(int pid) => true;

  @override
  Future<void> launch(String executable, List<String> arguments, {String? workingDirectory}) async {}
}
