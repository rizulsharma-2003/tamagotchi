// Where Mochi Cloud's API-trigger token is kept (the Mac's CloudTokenStore, in the login Keychain). The token can only start
// that one scheduled task, but it never goes in settings.json or a log: only a vault holds it. Here, the shape and the
// in-memory one for tests and demos; the Windows one (DPAPI) is platform/cloud_token_vault.dart.

abstract interface class CloudTokenVault {
  /// How it's kept, for Settings.
  String get description;

  /// The token, or null when none is saved (or it can't be opened).
  String? load();

  /// Replaces the saved token. False when it couldn't be kept.
  bool save(String token);

  void delete();
}

/// Keeps nothing past the run (tests, demos, a PC where nothing safer exists).
class MemoryCloudTokenVault implements CloudTokenVault {
  MemoryCloudTokenVault([this.token]);

  String? token;

  /// Tests: make saves fail.
  bool failing = false;

  @override
  String get description => 'memory only (nothing is kept)';

  @override
  String? load() => token;

  @override
  bool save(String value) {
    if (failing) return false;
    token = value;
    return true;
  }

  @override
  void delete() => token = null;
}
