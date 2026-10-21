import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the Ed25519 private key seed lives (Phase 5 requirement:
/// "protect private key storage").
///
/// The platform keystore wraps these values in ENCRYPTED storage -
/// Android Keystore, iOS Keychain, Windows Credential Manager. What that
/// defeats: casual file reads, app backups, and accidentally shipping the
/// private key in plain SQLite or log output. What it does NOT defeat:
/// an attacker with root on the device can still extract keys from a
/// running process - that limitation is documented, not hidden.
abstract class SecureKeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Production store: the platform's encrypted credential storage.
class PlatformKeyStore implements SecureKeyStore {
  const PlatformKeyStore();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory store for tests and CI.
///
/// Unit tests run without platform channels (flutter_secure_storage would
/// throw MissingPluginException under `flutter test`), so every test that
/// creates payments passes one of these instead. Sharing the same instance
/// across two providers simulates "the same device across an app restart".
class InMemoryKeyStore implements SecureKeyStore {
  InMemoryKeyStore([Map<String, String>? initial])
      : _values = {...?initial};

  final Map<String, String> _values;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}
