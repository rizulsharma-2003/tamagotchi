// Mochi for Windows updating itself (docs/SPRINT_2.md W29): the signed manifest (good, tampered, wrong key, unsigned),
// the zip's SHA-256, the relay's feed over HTTP (a fake client), the updater's states from "checking" to "ready" and
// the hand-off to the helper, and "Install Mochi" (detecting where Mochi runs, the copy, the shortcut, Settings ›
// Apps). Signed releases are made in the test with its own key; files live in a temporary folder.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mochi_desktop/src/update/self_install.dart';
import 'package:mochi_desktop/src/update/update_feed.dart';
import 'package:mochi_desktop/src/update/update_keys.dart';
import 'package:mochi_desktop/src/update/update_manifest.dart';
import 'package:mochi_desktop/src/update/update_signing.dart';
import 'package:mochi_desktop/src/update/updater.dart';
import 'package:mochi_link/mochi_link.dart';

import 'support/fakes.dart' show FakeStartup;
import 'support/update_fakes.dart';

void main() {
  setUpAll(loadReleaseKey);

  group('The signed manifest', () {
    test('reads every field and writes the same bytes back', () async {
      final release = await Release.make(minWindows: '10.0.17763');
      final manifest = UpdateManifest.parse(release.bytes);
      expect(manifest.version, '0.2.0');
      expect(manifest.build, 2);
      expect(manifest.file, 'Mochi-0.2.0-windows-x64.zip');
      expect(manifest.size, release.zip.length);
      expect(manifest.sha256, hasLength(64));
      expect(manifest.notes, 'Mochi keeps itself up to date.');
      expect(manifest.publishedAt, DateTime.utc(2026, 11, 7, 12));
      expect(manifest.encode(), release.bytes);
      expect(jsonDecode(utf8.decode(release.bytes)), containsPair('minWindows', '10.0.17763'));
    });

    test('refuses anything odd, field by field', () {
      Map<String, Object?> good() => {
        'version': '0.2.0',
        'build': 2,
        'file': 'Mochi-0.2.0-windows-x64.zip',
        'size': 15000000,
        'sha256': 'ab' * 32,
      };
      List<int> bytes(Map<String, Object?> json) => utf8.encode(jsonEncode(json));
      expect(UpdateManifest.parse(bytes(good())).notes, '');
      for (final (field, value) in [
        ('version', 'latest'),
        ('version', 2),
        ('build', 0),
        ('build', '2'),
        ('file', '../Mochi.zip'),
        ('file', r'C:\Mochi.zip'),
        ('file', 'Mochi.exe'),
        ('size', 0),
        ('size', 1 << 40),
        ('sha256', 'AB' * 32),
        ('sha256', 'ab' * 31),
        ('minWindows', 'Windows 11'),
      ]) {
        expect(() => UpdateManifest.parse(bytes({...good(), field: value})), throwsA(isA<ManifestException>()), reason: '$field: $value');
      }
      expect(() => UpdateManifest.parse(utf8.encode('not json')), throwsA(isA<ManifestException>()));
      expect(() => UpdateManifest.parse(utf8.encode('[1]')), throwsA(isA<ManifestException>()));
    });

    test('knows which Windows it runs on', () {
      const manifest = UpdateManifest(version: '0.2.0', build: 2, file: 'a.zip', size: 1, sha256: '', minWindows: '10.0.17763');
      expect(manifest.runsOn('10.0.22631'), isTrue);
      expect(manifest.runsOn('10.0.17763'), isTrue);
      expect(manifest.runsOn('10.0.17134'), isFalse);
      expect(manifest.runsOn('6.3.9600'), isFalse);
      expect(manifest.runsOn(null), isTrue);
      expect(windowsVersion('"Windows 10 Pro" 10.0 (Build 22631)'), '10.0.22631');
      expect(windowsVersion('Version 15.1 (Build 24B83)'), isNull);
    });
  });

  group('Signatures and checksums', () {
    test('a good signature checks out', () async {
      final release = await Release.make();
      expect(await UpdateSigning.verify(release.bytes, release.signature, releasePublicKey), isTrue);
      expect(UpdateSigning.base64UrlDecode(release.signature), hasLength(64));
      expect(release.signature, isNot(contains('=')), reason: 'base64url without padding, as manifest.sig');
    });

    test('a tampered manifest fails, by a single byte', () async {
      final release = await Release.make();
      final tampered = List<int>.of(release.bytes);
      final index = utf8.decode(tampered).indexOf('0.2.0');
      tampered[index] = '9'.codeUnitAt(0);
      expect(await UpdateSigning.verify(tampered, release.signature, releasePublicKey), isFalse);
      // A bigger size or another checksum: the same.
      final bigger = utf8.encode(utf8.decode(release.bytes).replaceFirst('"size":${release.zip.length}', '"size":${release.zip.length + 1}'));
      expect(await UpdateSigning.verify(bigger, release.signature, releasePublicKey), isFalse);
    });

    test('a signature by another key fails', () async {
      final release = await Release.make(seed: otherSeed);
      expect(await UpdateSigning.verify(release.bytes, release.signature, releasePublicKey), isFalse);
      expect(await UpdateSigning.verify(release.bytes, release.signature, await UpdateSigning.publicKey(otherSeed)), isTrue);
    });

    test('garbage is a failure, never an exception', () async {
      final release = await Release.make();
      for (final signature in ['', 'not base64!', 'AAAA', '${release.signature}AA', release.signature.substring(4)]) {
        expect(await UpdateSigning.verify(release.bytes, signature, releasePublicKey), isFalse, reason: signature);
      }
      expect(await UpdateSigning.verify(release.bytes, release.signature, const [1, 2, 3]), isFalse);
      expect(await UpdateSigning.verify(release.bytes, release.signature, const []), isFalse);
    });

    test('SHA-256 of a file, as shasum says', () async {
      // FIPS 180-2's "abc".
      expect(await sha256Of(utf8.encode('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(UpdateSigning.sameDigest('ab' * 32, 'ab' * 32), isTrue);
      expect(UpdateSigning.sameDigest('ab' * 32, '${'ab' * 31}ac'), isFalse);
      expect(UpdateSigning.sameDigest('ab', 'abc'), isFalse);
    });

    test('this build has no release key until the release script adds one', () {
      // scripts/release-windows.sh fills it in (and checks it) on the release Mac.
      final key = UpdateSigning.base64UrlDecode(windowsUpdatePublicKey);
      expect(windowsUpdatePublicKey.isEmpty || key?.length == 32, isTrue);
    });
  });

  group('The relay feed', () {
    final credentials = LinkCredentials(
      relay: 'relay.test',
      room: 'a' * 64,
      device: 'dev_pc',
      secret: 'pc-secret',
      key: LinkCrypto.base64url(List.filled(32, 1)),
      role: 'host',
    );
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('mochi_feed'));
    tearDown(() => temp.deleteSync(recursive: true));

    RelayUpdateFeed feed(MockClient client, {LinkCredentials? as}) =>
        RelayUpdateFeed(credentials: () async => as ?? credentials, client: () => client);

    test('asks for the manifest with this PC’s credential and takes the signature from the header', () async {
      final requests = <http.BaseRequest>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response.bytes(utf8.encode('{"m":1}'), 200, headers: {'x-mochi-signature': 'sig'});
      });
      final signed = await feed(client).manifest();
      expect(utf8.decode(signed.bytes), '{"m":1}');
      expect(signed.signature, 'sig');
      expect(requests.single.url.toString(), 'https://relay.test/v1/rooms/${'a' * 64}/updates/windows/manifest');
      expect(requests.single.headers['authorization'], 'Bearer dev_pc.pc-secret');
    });

    test('falls back to manifest.sig', () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/manifest')) return http.Response('{"m":1}', 200);
        expect(request.url.path, endsWith('/file/manifest.sig'));
        return http.Response('sig-from-file\n', 200);
      });
      expect((await feed(client).manifest()).signature, 'sig-from-file');
    });

    test('says what went wrong: offline, refused, nothing published', () async {
      Future<UpdateFeedException> failure(MockClient client, {bool noRoom = false}) async {
        try {
          await RelayUpdateFeed(credentials: () async => noRoom ? null : credentials, client: () => client).manifest();
        } on UpdateFeedException catch (error) {
          return error;
        }
        fail('no exception');
      }

      final offline = await failure(MockClient((_) async => throw http.ClientException('no network')));
      expect(offline.offline, isTrue);
      final noRoom = await failure(MockClient((_) async => http.Response('', 200)), noRoom: true);
      expect(noRoom.offline, isTrue);
      final refused = await failure(MockClient((_) async => http.Response('{"error":"unauthorized"}', 401)));
      expect([refused.offline, refused.status], [false, 401]);
      expect(refused.message, contains("didn't accept"));
      final none = await failure(MockClient((_) async => http.Response('{"error":"not_found"}', 404)));
      expect(none.nothingPublished, isTrue);
      final unavailable = await failure(MockClient((_) async => http.Response('{"error":"updates_unavailable"}', 503)));
      expect(unavailable.message, contains("aren't set up"));
    });

    test('downloads the zip, and resumes an interrupted one from where it stopped', () async {
      final zip = List.generate(10000, (i) => (i * 7) % 256);
      final ranges = <String?>[];
      final client = MockClient((request) async {
        ranges.add(request.headers['range']);
        expect(request.url.path, endsWith('/file/Mochi-0.2.0-windows-x64.zip'));
        final range = request.headers['range'];
        if (range == null) return http.Response.bytes(zip, 200);
        final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
        return http.Response.bytes(zip.sublist(from), 206);
      });
      final target = '${temp.path}${sep}Mochi.zip';
      // What an interrupted download left.
      File('$target.part').writeAsBytesSync(zip.sublist(0, 4000));
      final seen = <int>[];
      await feed(client).download('Mochi-0.2.0-windows-x64.zip', target, size: zip.length, progress: seen.add);
      expect(ranges, ['bytes=4000-']);
      expect(File(target).readAsBytesSync(), zip);
      expect(File('$target.part').existsSync(), isFalse);
      expect(seen.last, zip.length);

      // A relay that sends the whole file anyway: the .part starts over.
      File('$target.part').writeAsBytesSync(zip.sublist(0, 4000));
      final whole = MockClient((request) async => http.Response.bytes(zip, 200));
      await feed(whole).download('Mochi-0.2.0-windows-x64.zip', target, size: zip.length);
      expect(File(target).readAsBytesSync(), zip);
    });

    test('a download that is cut off keeps its .part; one that is too big is thrown away', () async {
      final zip = List.generate(10000, (i) => i % 256);
      final target = '${temp.path}${sep}Mochi.zip';
      final cut = MockClient.streaming((request, _) async {
        final stream = Stream<List<int>>.fromIterable([zip.sublist(0, 3000)]).asyncExpand(
          (chunk) => Stream<List<int>>.fromFutures([Future.value(chunk), Future.error(http.ClientException('connection reset'))]),
        );
        return http.StreamedResponse(stream, 200);
      });
      await expectLater(
        feed(cut).download('Mochi.zip', target, size: zip.length),
        throwsA(isA<UpdateFeedException>().having((error) => error.offline, 'offline', isTrue)),
      );
      expect(File('$target.part').lengthSync(), 3000);

      final huge = MockClient((request) async => http.Response.bytes(List.filled(20000, 1), 200));
      await expectLater(feed(huge).download('Mochi.zip', '${temp.path}${sep}other.zip', size: zip.length), throwsA(isA<UpdateFeedException>()));
      expect(File('${temp.path}${sep}other.zip.part').existsSync(), isFalse);
      expect(File('${temp.path}${sep}other.zip').existsSync(), isFalse);
    });
  });

  group('The updater', () {
    late UpdateRig rig;

    setUp(() => rig = UpdateRig());
    tearDown(() => rig.dispose());

    test('up to date when the signed manifest is this build', () async {
      rig.feed.publish(await Release.make(version: '0.1.0', build: 1));
      final updater = rig.updater()..start();
      addTearDown(updater.dispose);
      expect(updater.phase, UpdatePhase.idle);
      await updater.check();
      expect(updater.phase, UpdatePhase.upToDate);
      expect(updater.checkedAt, DateTime(2026, 11, 7, 10, 42));
      expect(rig.feed.downloads, 0);
    });

    test('a newer release: downloaded, checked, unpacked and ready; Mochi is told once', () async {
      final release = await Release.make();
      rig.feed.publish(release);
      final told = <ReadyUpdate>[];
      final phases = <UpdatePhase>[];
      final updater = rig.updater()..onReady = told.add;
      updater.addListener(() => phases.add(updater.phase));
      updater.start();
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.phase, UpdatePhase.ready);
      expect(phases.toSet().containsAll([UpdatePhase.checking, UpdatePhase.available, UpdatePhase.downloading, UpdatePhase.verifying]), isTrue);
      expect(told.single.version, '0.2.0');
      expect(updater.newVersion, '0.2.0');
      expect(updater.notes, 'Mochi keeps itself up to date.');
      final ready = readJson(rig.files.ready);
      expect(ready['build'], 2);
      expect(read('${ready['root']}${sep}Mochi.exe'), 'Mochi 0.2.0');
      expect(read('${ready['root']}${sep}data${sep}app.so'), 'app 0.2.0');
      expect(Directory(rig.files.downloads).listSync(), isEmpty, reason: 'the zip goes once unpacked');
      expect(read(rig.exe), 'Mochi 0.1.0', reason: 'nothing is installed until Mochi restarts');

      // Checking again finds the same release: still ready, nothing downloaded twice.
      await updater.check();
      expect(updater.phase, UpdatePhase.ready);
      expect(rig.feed.downloads, 1);
      expect(told, hasLength(1));
    });

    test('hashes and unpacks on other isolates, as the app does (nothing of the updater has to cross)', () async {
      rig.feed.publish(await Release.make());
      final updater = rig.updater(background: true)..start();
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.phase, UpdatePhase.ready, reason: updater.problem);
      expect(read('${updater.ready!.root}${sep}Mochi.exe'), 'Mochi 0.2.0');

      // The same for "Install Mochi": the copy runs on another isolate too.
      final from = '${rig.temp.path}${sep}Downloads${sep}Mochi';
      appFolder(from, '0.2.0');
      Directory(rig.layout.installDirectory).deleteSync(recursive: true);
      final installer = SelfInstaller(layout: rig.layout, executable: '$from${sep}Mochi.exe', version: '0.2.0', system: FakeInstallSystem());
      expect(await installer.install(), isTrue, reason: installer.problem);
      expect(read(rig.layout.exe), 'Mochi 0.2.0');
    });

    test('never takes a manifest without a signature', () async {
      final release = await Release.make();
      rig.feed
        ..publish(release)
        ..answer = SignedManifest(release.bytes, null);
      final updater = rig.updater()..start();
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.phase, UpdatePhase.couldNotVerify);
      expect(rig.feed.downloads, 0);
      expect(File(rig.files.ready).existsSync(), isFalse);
    });

    test('a tampered manifest is thrown away', () async {
      final release = await Release.make();
      final tampered = utf8.encode(utf8.decode(release.bytes).replaceFirst(release.manifest.sha256, 'cd' * 32));
      rig.feed
        ..publish(release)
        ..answer = SignedManifest(tampered, release.signature);
      final updater = rig.updater()..start();
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.phase, UpdatePhase.couldNotVerify);
      expect(updater.problem, contains('release key'));
      expect(rig.feed.downloads, 0);
    });

    test('a manifest signed with another key is thrown away', () async {
      rig.feed.publish(await Release.make(seed: otherSeed));
      final updater = rig.updater()..start();
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.phase, UpdatePhase.couldNotVerify);
      expect(rig.feed.downloads, 0);
    });

    test('a zip that doesn’t match the signed checksum is thrown away', () async {
      final release = await Release.make(sha256: 'ef' * 32);
      rig.feed.publish(release);
      final updater = rig.updater()..start();
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.phase, UpdatePhase.couldNotVerify);
      expect(updater.problem, contains('checksum'));
      expect(rig.feed.downloads, 1);
      expect(Directory(rig.files.downloads).listSync(), isEmpty);
      expect(Directory(rig.files.staged).existsSync() && Directory(rig.files.staged).listSync().isNotEmpty, isFalse);
      expect(File(rig.files.ready).existsSync(), isFalse);
    });

    test('a zip without Mochi.exe is never staged', () async {
      rig.feed.publish(await Release.make(zip: appZip('0.2.0', withExe: false)));
      final updater = rig.updater()..start();
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.phase, UpdatePhase.failed);
      expect(File(rig.files.ready).existsSync(), isFalse);
    });

    test('a zip with Mochi at its top level works too', () async {
      rig.feed.publish(await Release.make(zip: appZip('0.2.0', topFolder: false)));
      final updater = rig.updater()..start();
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.phase, UpdatePhase.ready);
      expect(read('${updater.ready!.root}${sep}Mochi.exe'), 'Mochi 0.2.0');
    });

    test('automatic downloads off: Mochi says a version is there, and downloads when asked', () async {
      rig
        ..autoDownload = false
        ..feed.publish(await Release.make());
      final updater = rig.updater()..start();
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.phase, UpdatePhase.available);
      expect(rig.feed.downloads, 0);
      await updater.download();
      expect(updater.phase, UpdatePhase.ready);
    });

    test('offline: says so; a copy that’s already ready stays ready', () async {
      rig.feed.manifestError = const UpdateFeedException("Couldn't reach your Mochi Link relay.", offline: true);
      final updater = rig.updater()..start();
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.phase, UpdatePhase.offline);
      expect(updater.problem, contains("Couldn't reach"));

      rig.feed
        ..manifestError = null
        ..publish(await Release.make());
      await updater.check();
      expect(updater.phase, UpdatePhase.ready);
      rig.feed.manifestError = const UpdateFeedException('offline', offline: true);
      await updater.check();
      expect(updater.phase, UpdatePhase.ready);
    });

    test('a download cut off midway says offline', () async {
      rig.feed
        ..publish(await Release.make())
        ..downloadError = const UpdateFeedException('The download was cut off.', offline: true);
      final updater = rig.updater()..start();
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.phase, UpdatePhase.offline);
      expect(File(rig.files.ready).existsSync(), isFalse);
    });

    test('nothing published yet counts as up to date', () async {
      final updater = rig.updater()..start();
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.phase, UpdatePhase.upToDate);
    });

    test('a release that needs a newer Windows is left alone', () async {
      rig.feed.publish(await Release.make(minWindows: '10.0.26100'));
      final updater = rig.updater(windowsVersion: '10.0.19045')..start();
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.phase, UpdatePhase.failed);
      expect(updater.problem, 'Mochi 0.2.0 needs Windows 10.0.26100 or newer.');
      expect(rig.feed.downloads, 0);
    });

    test('an even newer release replaces the one waiting', () async {
      rig.feed.publish(await Release.make());
      final updater = rig.updater()..start();
      addTearDown(updater.dispose);
      await updater.check();
      final first = updater.ready!.root;
      rig.feed.publish(await Release.make(version: '0.3.0', build: 3));
      await updater.check();
      expect(updater.phase, UpdatePhase.ready);
      expect(updater.ready!.version, '0.3.0');
      expect(Directory(first).existsSync(), isFalse);
    });

    test('not installed: updates are off and the relay is never asked', () async {
      rig.feed.publish(await Release.make());
      final updater = rig.updater(installed: false)..start();
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.phase, UpdatePhase.notInstalled);
      expect(rig.feed.manifests, 0);
    });

    test('a build without the release key never checks', () async {
      final updater = rig.updater(publicKey: const [])..start();
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.phase, UpdatePhase.unsupported);
      expect(rig.feed.manifests, 0);
    });

    test('Restart to Update hands the copy to a helper outside the app folder', () async {
      rig.feed.publish(await Release.make());
      final updater = rig.updater()..start();
      addTearDown(updater.dispose);
      await updater.check();
      final root = updater.ready!.root;
      expect(await updater.restartToUpdate(), isNull);
      expect(updater.phase, UpdatePhase.applying);
      final runner = '${rig.files.runnerDirectory}$sep$helperName';
      expect(read(runner), 'helper 0.1.0', reason: 'the installed copy’s helper, copied out of the folder it replaces');
      expect(rig.processes.launched.first.arguments, ['warm'], reason: 'started once as soon as the update was ready');
      expect(rig.processes.launched.first.exe, runner);
      final launch = rig.processes.launched.last;
      expect(launch.exe, runner);
      expect(launch.arguments, ['update', '--staged', root, '--app', rig.layout.installDirectory, '--pid', '4242', '--version', '0.2.0', '--build', '2']);
      expect(File(rig.files.ready).existsSync(), isFalse);
      expect(File(rig.files.applying).existsSync(), isTrue, reason: 'not tried again at every launch if it fails');
    });

    test('a helper that can’t start leaves the update ready', () async {
      rig.feed.publish(await Release.make());
      final updater = rig.updater()..start();
      addTearDown(updater.dispose);
      await updater.check();
      rig.processes.failLaunch = const ProcessException('mochi_hook.exe', []);
      expect(await updater.restartToUpdate(), contains("couldn't be started"));
      expect(File(rig.files.ready).existsSync(), isTrue);
      expect(updater.phase, UpdatePhase.ready);
    });

    test('at the next launch a waiting copy goes in before any window', () async {
      rig.feed.publish(await Release.make());
      final first = rig.updater()..start();
      await first.check();
      first.dispose();

      final next = rig.updater();
      addTearDown(next.dispose);
      rig.processes.launched.clear();
      expect(await next.applyPendingAtLaunch(), isTrue);
      expect(rig.processes.launched.single.arguments.first, 'update');

      // A copy that's no newer than the running one, or a report still unread: nothing happens.
      rig.processes.launched.clear();
      File(rig.files.applying).renameSync(rig.files.ready);
      expect(await rig.updater(currentBuild: 2).applyPendingAtLaunch(), isFalse);
      expect(File(rig.files.ready).existsSync(), isFalse, reason: 'a stale copy is cleared');
      expect(await rig.updater(installed: false).applyPendingAtLaunch(), isFalse);
      expect(rig.processes.launched, isEmpty);
    });

    test('after an update: the old copy goes and Mochi says it was updated', () async {
      Directory(rig.layout.oldDirectory).createSync(recursive: true);
      File(rig.files.result)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'ok': true, 'version': '0.2.0', 'build': 2}));
      final updater = rig.updater(currentBuild: 2, currentVersion: '0.2.0')..start();
      addTearDown(updater.dispose);
      expect(updater.updatedTo, '0.2.0');
      expect(Directory(rig.layout.oldDirectory).existsSync(), isFalse);
      expect(File(rig.files.result).existsSync(), isFalse);
      expect(updater.phase, UpdatePhase.idle);
    });

    test('after a failed update: Settings says why, and Mochi tries again later', () async {
      File(rig.files.result)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'ok': false, 'version': '0.2.0', 'error': "Mochi's folder is still in use."}));
      final updater = rig.updater()..start();
      addTearDown(updater.dispose);
      expect(updater.phase, UpdatePhase.failed);
      expect(updater.problem, contains("Mochi's folder is still in use."));
      expect(updater.updatedTo, isNull);
    });

    test('an update that never reported back is said too', () async {
      File(rig.files.applying)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{}');
      final updater = rig.updater()..start();
      addTearDown(updater.dispose);
      expect(updater.phase, UpdatePhase.failed);
      expect(updater.problem, contains("didn't finish"));
      expect(File(rig.files.applying).existsSync(), isFalse);
    });
  });

  group('Install Mochi', () {
    late UpdateRig rig;
    late String downloads;
    late FakeInstallSystem system;

    setUp(() {
      rig = UpdateRig();
      Directory(rig.layout.installDirectory).deleteSync(recursive: true);
      downloads = '${rig.temp.path}${sep}Downloads${sep}Mochi-0.2.0-windows-x64${sep}Mochi';
      appFolder(downloads, '0.2.0');
      system = FakeInstallSystem();
    });
    tearDown(() => rig.dispose());

    SelfInstaller installer({String? exe, FakeStartup? startup, List<String>? movedStartup}) => SelfInstaller(
      layout: rig.layout,
      executable: exe ?? '$downloads${sep}Mochi.exe',
      version: '0.2.0',
      system: system,
      startup: startup,
      startupFor: (exe) {
        movedStartup?.add(exe);
        return FakeStartup();
      },
      processes: rig.processes,
      processId: () => 4242,
      clock: () => DateTime(2026, 11, 7),
      copyInBackground: false,
    );

    test('knows where it runs from', () {
      expect(installer().installed, isFalse);
      expect(installer().runningFrom, downloads);
      expect(installer(exe: rig.layout.exe).installed, isTrue);
      expect(SelfInstaller.unsupported().supported, isFalse);
      expect(SelfInstaller.unsupported().installed, isFalse);
    });

    test('copies itself into place with a shortcut and a Settings › Apps entry, then hands over', () async {
      final moved = <String>[];
      final copy = installer(startup: FakeStartup(enabled: true), movedStartup: moved);
      expect(await copy.install(), isTrue);
      expect(copy.problem, isNull);
      expect(read(rig.layout.exe), 'Mochi 0.2.0');
      expect(read('${rig.layout.installDirectory}${sep}data${sep}app.so'), 'app 0.2.0');
      expect(read('$downloads${sep}Mochi.exe'), 'Mochi 0.2.0', reason: 'the downloaded copy stays where it is');

      final shortcut = system.shortcuts.single;
      expect(shortcut.path, rig.layout.shortcut);
      expect(shortcut.target, rig.layout.exe);
      expect(shortcut.workingDirectory, rig.layout.installDirectory);
      expect(shortcut.appUserModelId, 'InsideEdge.Mochi');

      final entry = system.keys[rig.layout.uninstallKey]!;
      expect(entry['DisplayName'], 'Mochi');
      expect(entry['DisplayVersion'], '0.2.0');
      expect(entry['Publisher'], 'InsideEdge');
      expect(entry['InstallLocation'], rig.layout.installDirectory);
      expect(entry['UninstallString'], '"${rig.layout.helper}" uninstall');
      expect(entry['QuietUninstallString'], '"${rig.layout.helper}" uninstall --quiet');
      expect(entry['DisplayIcon'], '"${rig.layout.exe}",0');
      expect(entry['InstallDate'], '20261107');
      expect(entry['NoModify'], 1);
      expect(entry['EstimatedSize'], greaterThan(0));

      expect(moved, [rig.layout.exe], reason: 'Start with Windows now starts the installed copy');

      expect(await copy.relaunchInstalled(), isNull);
      final launch = rig.processes.launched.single;
      expect(launch.exe, rig.layout.helper);
      expect(launch.arguments, ['launch', '--after', '4242', '--exe', rig.layout.exe, '--', '--installed']);
    });

    test('replaces an older install; Mochi’s data folder is never touched', () async {
      appFolder(rig.layout.installDirectory, '0.1.0');
      File(rig.paths.settingsFile)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"petName":"Bao"}');
      final copy = installer(startup: FakeStartup());
      expect(await copy.install(), isTrue);
      expect(read(rig.layout.exe), 'Mochi 0.2.0');
      expect(Directory(rig.layout.oldDirectory).existsSync(), isFalse);
      expect(Directory(rig.layout.newDirectory).existsSync(), isFalse);
      expect(read(rig.paths.settingsFile), '{"petName":"Bao"}');
    });

    test('Start with Windows that was off stays off', () async {
      final moved = <String>[];
      expect(await installer(startup: FakeStartup(), movedStartup: moved).install(), isTrue);
      expect(moved, isEmpty);
    });

    test('a failure is said in words and leaves no half copy', () async {
      File('$downloads${sep}Mochi.exe').deleteSync();
      final copy = installer();
      expect(await copy.install(), isFalse);
      expect(copy.problem, contains('incomplete'));
      expect(Directory(rig.layout.installDirectory).existsSync(), isFalse);
      expect(system.keys, isEmpty);

      appFolder(downloads, '0.2.0');
      system.refuse = true;
      final refused = installer();
      expect(await refused.install(), isFalse);
      expect(refused.problem, contains('shortcut'));
    });

    test('the installed copy keeps Settings › Apps at its version and remakes a lost shortcut', () async {
      appFolder(rig.layout.installDirectory, '0.2.0');
      system.keys[rig.layout.uninstallKey] = {'DisplayVersion': '0.1.0'};
      installer(exe: rig.layout.exe).refreshAtLaunch();
      expect(system.keys[rig.layout.uninstallKey]!['DisplayVersion'], '0.2.0');
      expect(system.shortcuts, hasLength(1));
      // Already right: nothing written.
      system.shortcuts.clear();
      installer(exe: rig.layout.exe).refreshAtLaunch();
      expect(system.shortcuts, isEmpty);
      // A copy elsewhere never registers itself.
      installer().refreshAtLaunch();
      expect(system.shortcuts, isEmpty);
    });
  });
}
