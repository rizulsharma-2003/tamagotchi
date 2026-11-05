import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mochi_link/mochi_link.dart';

/// Where this phone keeps its place in the Mac's room: the relay, the room, its device credential and the room key K.
abstract interface class CredentialStore {
  Future<LinkCredentials?> load();

  Future<void> save(LinkCredentials credentials);

  Future<void> delete();
}

/// Android Keystore-backed storage (flutter_secure_storage: AES-GCM with a key held in the Keystore). Nothing here is
/// backed up or moved to another phone (the manifest's backup rules exclude everything).
///
/// `migrateWithBackup` skips the plugin's probe for pre-v10 EncryptedSharedPreferences data, which this app never
/// wrote: on every launch the probe fails ("bad base-64"), logs a stack trace and costs a Keystore round trip.
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage(aOptions: AndroidOptions(storageNamespace: 'mochi_link', migrateWithBackup: true));

  final FlutterSecureStorage _storage;

  static const String _key = 'link.credentials';

  @override
  Future<LinkCredentials?> load() async {
    final text = await _storage.read(key: _key);
    return text == null ? null : LinkCredentials.decode(text);
  }

  @override
  Future<void> save(LinkCredentials credentials) => _storage.write(key: _key, value: credentials.encode());

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

/// For tests and previews.
class MemoryCredentialStore implements CredentialStore {
  MemoryCredentialStore([this.saved]);

  LinkCredentials? saved;

  @override
  Future<LinkCredentials?> load() async => saved;

  @override
  Future<void> save(LinkCredentials credentials) async => saved = credentials;

  @override
  Future<void> delete() async => saved = null;
}
