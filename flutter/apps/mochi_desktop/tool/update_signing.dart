// The release key for Mochi for Windows' updates, on the release Mac (scripts/release-windows.sh runs this):
//
//   dart tool/update_signing.dart ensure-key [--service S]   makes the key pair once (the private half straight into
//                                                            the login Keychain), prints the PUBLIC key (base64url)
//   dart tool/update_signing.dart public-key [--service S]   prints the public key of the Keychain's key
//   dart tool/update_signing.dart manifest --version V --build N --file F --size BYTES --sha256 HEX
//                                [--notes-file PATH] [--min-windows 10.0.17763] --out manifest.json
//                                                            writes the manifest, checked by the app's own parser
//   dart tool/update_signing.dart sign --manifest manifest.json --out manifest.sig [--service S]
//                                                            signs it with the Keychain's key (and checks the result)
//   dart tool/update_signing.dart verify --manifest manifest.json --signature manifest.sig --public-key B64
//   dart tool/update_signing.dart delete-key --service S     only for a throwaway key (a service ending in -dryrun)
//
// The private key is never printed, written to a file or passed on a command line: it goes to and from
// /usr/bin/security over pipes. Its Keychain item is service "mochi-windows-update-signing", account "release".
// It signs the same bytes with the same code (lib/src/update) the app verifies with.

import 'dart:convert';
import 'dart:io';

import 'package:mochi_desktop/src/update/update_manifest.dart';
import 'package:mochi_desktop/src/update/update_signing.dart';

const String defaultService = 'mochi-windows-update-signing';
const String account = 'release';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) _usage();
  final options = _options(arguments.sublist(1));
  final service = options['--service'] ?? defaultService;
  try {
    switch (arguments.first) {
      case 'ensure-key':
        var seed = await _readSeed(service);
        if (seed == null) {
          seed = UpdateSigning.newSeed();
          await _storeSeed(service, seed);
          stderr.writeln('Made a new release key; its private half is in the login Keychain ($service).');
        }
        stdout.writeln(UpdateSigning.base64UrlEncode(await UpdateSigning.publicKey(seed)));
      case 'public-key':
        final seed = await _readSeed(service) ?? _fail('No release key in the Keychain ($service). Run ensure-key first.');
        stdout.writeln(UpdateSigning.base64UrlEncode(await UpdateSigning.publicKey(seed)));
      case 'manifest':
        final notesFile = options['--notes-file'];
        final manifest = UpdateManifest(
          version: _required(options, '--version'),
          build: int.tryParse(_required(options, '--build')) ?? _fail('--build is a number.'),
          file: _required(options, '--file'),
          size: int.tryParse(_required(options, '--size')) ?? _fail('--size is a number.'),
          sha256: _required(options, '--sha256').toLowerCase(),
          notes: notesFile == null ? '' : File(notesFile).readAsStringSync().trim(),
          publishedAt: DateTime.now().toUtc(),
          minWindows: options['--min-windows'],
        );
        final bytes = manifest.encode();
        // Whatever the app wouldn't accept is refused here, before anything is signed.
        UpdateManifest.parse(bytes);
        File(_required(options, '--out')).writeAsBytesSync(bytes);
      case 'sign':
        final seed = await _readSeed(service) ?? _fail('No release key in the Keychain ($service). Run ensure-key first.');
        final manifest = File(_required(options, '--manifest')).readAsBytesSync();
        UpdateManifest.parse(manifest);
        final signature = await UpdateSigning.sign(manifest, seed);
        if (!await UpdateSigning.verify(manifest, signature, await UpdateSigning.publicKey(seed))) _fail('The signature did not check out.');
        File(_required(options, '--out')).writeAsStringSync('$signature\n');
      case 'verify':
        final manifest = File(_required(options, '--manifest')).readAsBytesSync();
        final signature = File(_required(options, '--signature')).readAsStringSync().trim();
        final key = UpdateSigning.base64UrlDecode(_required(options, '--public-key')) ?? _fail('--public-key is not base64url.');
        if (!await UpdateSigning.verify(manifest, signature, key)) _fail('The signature does NOT match that public key.');
        stdout.writeln('The signature matches.');
      case 'delete-key':
        if (!service.endsWith('-dryrun')) _fail('Only a throwaway key (a service ending in -dryrun) can be deleted here.');
        await _security(['delete-generic-password', '-s', service, '-a', account]);
      default:
        _usage();
    }
  } on ManifestException catch (error) {
    _fail(error.message);
  } on FileSystemException catch (error) {
    _fail('${error.path}: ${error.osError?.message ?? error.message}');
  }
}

Future<List<int>?> _readSeed(String service) async {
  final result = await _security(['find-generic-password', '-s', service, '-a', account, '-w']);
  if (result.exitCode != 0) return null;
  final seed = UpdateSigning.base64UrlDecode(result.output.trim());
  if (seed == null || seed.length != UpdateSigning.keyLength) _fail('The Keychain item $service is not a release key.');
  return seed;
}

Future<void> _storeSeed(String service, List<int> seed) async {
  // base64url has no spaces or quotes: one safe word on security's own command line, read from its stdin.
  final secret = UpdateSigning.base64UrlEncode(seed);
  final result = await _security(
    ['-i'],
    input: 'add-generic-password -s "$service" -a "$account" -l "Mochi for Windows update signing key" -w $secret\n',
  );
  if (result.exitCode != 0 || await _readSeed(service) == null) _fail("Couldn't save the release key in the Keychain.");
}

/// Runs /usr/bin/security; what it prints is returned, never shown.
Future<({int exitCode, String output})> _security(List<String> arguments, {String? input}) async {
  final process = await Process.start('/usr/bin/security', arguments);
  if (input != null) process.stdin.write(input);
  await process.stdin.close();
  final output = await process.stdout.transform(utf8.decoder).join();
  await process.stderr.drain<void>();
  return (exitCode: await process.exitCode, output: output);
}

Map<String, String> _options(List<String> args) {
  final options = <String, String>{};
  for (var i = 0; i + 1 < args.length; i += 2) {
    if (!args[i].startsWith('--')) _usage();
    options[args[i]] = args[i + 1];
  }
  return options;
}

String _required(Map<String, String> options, String name) => options[name] ?? _fail('$name is required.');

Never _fail(String message) {
  stderr.writeln('update_signing: $message');
  exit(1);
}

Never _usage() {
  stderr.writeln('usage: dart tool/update_signing.dart ensure-key|public-key|manifest|sign|verify|delete-key [options]');
  exit(64);
}
