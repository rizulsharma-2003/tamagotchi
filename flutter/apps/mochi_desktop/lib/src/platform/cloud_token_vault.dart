import 'dart:convert';
import 'dart:io';

import 'package:mochi_wire/mochi_wire.dart';

import '../core/agent/cloud_token_vault.dart';
import 'win32.dart';

/// Picks the platform's vault for Mochi Cloud's token: DPAPI on Windows. Elsewhere (the macOS development build, demos)
/// the token is kept in memory only, for the run: it is never written to a file in the clear.
CloudTokenVault platformCloudTokenVault(BridgePaths paths) {
  if (Platform.isWindows) return DpapiCloudTokenVault(paths.join(paths.linkDirectory, 'cloud-trigger.dpapi'));
  return MemoryCloudTokenVault();
}

/// Windows: the token sealed with DPAPI for the signed-in user, in `%LOCALAPPDATA%\Mochi\Link\cloud-trigger.dpapi`. Like
/// the link's own vault, but its own file and its own entropy, so neither file opens with the other's seal.
class DpapiCloudTokenVault implements CloudTokenVault {
  DpapiCloudTokenVault(this.path);

  final String path;

  /// Mixed into the seal, so another app running as the same user can't simply ask DPAPI to open the file.
  static final List<int> entropy = utf8.encode('mochi-cloud/v1 trigger token');

  @override
  String get description => 'Windows Data Protection (this user, this PC)';

  @override
  String? load() {
    final file = File(path);
    try {
      if (!file.existsSync()) return null;
      final token = utf8.decode(Dpapi.unprotect(file.readAsBytesSync(), entropy: entropy));
      return token.isEmpty ? null : token;
    } on Object {
      return null;
    }
  }

  @override
  bool save(String token) {
    try {
      final sealed = Dpapi.protect(utf8.encode(token), entropy: entropy);
      final file = File(path);
      file.parent.createSync(recursive: true);
      final temporary = File('$path.tmp')..writeAsBytesSync(sealed, flush: true);
      temporary.renameSync(path);
      return true;
    } on Object {
      return false;
    }
  }

  @override
  void delete() {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on Object {
      // Nothing to forget.
    }
  }
}
