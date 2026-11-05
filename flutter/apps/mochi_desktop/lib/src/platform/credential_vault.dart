import 'dart:convert';
import 'dart:io';

import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_wire/mochi_wire.dart';

import 'win32.dart';

/// Where this PC keeps its place in its Mochi Link room: the relay, the room, its device credential and the room key
/// K. Nothing here is ever logged.
abstract interface class CredentialVault {
  /// How it's kept, for Settings ("Windows Data Protection").
  String get description;

  Future<LinkCredentials?> load();

  Future<void> save(LinkCredentials credentials);

  Future<void> delete();
}

/// Picks the platform's vault: DPAPI on Windows, the login Keychain on macOS (the development build).
/// `MOCHI_DESKTOP_VAULT=memory` keeps nothing at all (demos and screenshots).
CredentialVault platformVault(BridgePaths paths, {Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  if (env['MOCHI_DESKTOP_VAULT'] == 'memory') return MemoryVault();
  if (Platform.isWindows) return DpapiVault('${paths.linkDirectory}\\credentials.dpapi');
  if (Platform.isMacOS) return KeychainVault(account: 'link:${ProjectIdentity.key(paths.home)}');
  return MemoryVault();
}

/// Windows: the credentials sealed with DPAPI for the signed-in user, in `%LOCALAPPDATA%\Mochi\Link`.
class DpapiVault implements CredentialVault {
  DpapiVault(this.path);

  final String path;

  /// Mixed into the seal, so another app running as the same user can't simply ask DPAPI to open the file.
  static final List<int> _entropy = utf8.encode('mochi-link/v1 credentials');

  @override
  String get description => 'Windows Data Protection (this user, this PC)';

  @override
  Future<LinkCredentials?> load() async {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      return LinkCredentials.decode(utf8.decode(Dpapi.unprotect(file.readAsBytesSync(), entropy: _entropy)));
    } on Object {
      return null;
    }
  }

  @override
  Future<void> save(LinkCredentials credentials) async {
    final sealed = Dpapi.protect(utf8.encode(credentials.encode()), entropy: _entropy);
    final file = File(path);
    file.parent.createSync(recursive: true);
    final temporary = File('$path.tmp')..writeAsBytesSync(sealed, flush: true);
    temporary.renameSync(path);
  }

  @override
  Future<void> delete() async {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  }
}

/// Runs `/usr/bin/security` with commands on stdin (`security -i`), so a secret never appears in a process list.
typedef SecurityTool = Future<({int exitCode, String output})> Function(List<String> arguments, {String? input});

Future<({int exitCode, String output})> _runSecurity(List<String> arguments, {String? input}) async {
  final process = await Process.start('/usr/bin/security', arguments);
  if (input != null) process.stdin.write(input);
  await process.stdin.close();
  final output = await process.stdout.transform(utf8.decoder).join();
  await process.stderr.drain<void>();
  return (exitCode: await process.exitCode, output: output);
}

/// macOS (the development build): a generic password in the login Keychain, service "Mochi Desktop (development)".
class KeychainVault implements CredentialVault {
  KeychainVault({required this.account, SecurityTool? security}) : _security = security ?? _runSecurity;

  static const String service = 'Mochi Desktop (development)';

  final String account;
  final SecurityTool _security;

  @override
  String get description => 'the macOS Keychain';

  @override
  Future<LinkCredentials?> load() async {
    final result = await _security(['find-generic-password', '-s', service, '-a', account, '-w']);
    if (result.exitCode != 0) return null;
    try {
      return LinkCredentials.decode(utf8.decode(base64.decode(result.output.trim())));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> save(LinkCredentials credentials) async {
    // base64 has no spaces or quotes, so it's one safe word on security's command line (read from stdin).
    final secret = base64.encode(utf8.encode(credentials.encode()));
    final result = await _security(['-i'], input: 'add-generic-password -U -s "$service" -a "$account" -w $secret\n');
    if (result.exitCode != 0) throw StateError("Couldn't save the link in the Keychain.");
  }

  @override
  Future<void> delete() async {
    await _security(['delete-generic-password', '-s', service, '-a', account]);
  }
}

/// Keeps nothing (tests, demos).
class MemoryVault implements CredentialVault {
  MemoryVault([this.saved]);

  LinkCredentials? saved;

  @override
  String get description => 'memory only (nothing is kept)';

  @override
  Future<LinkCredentials?> load() async => saved;

  @override
  Future<void> save(LinkCredentials credentials) async => saved = credentials;

  @override
  Future<void> delete() async => saved = null;
}
