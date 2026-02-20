import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageHelper {
  SecureStorageHelper._();
  static final SecureStorageHelper instance = SecureStorageHelper._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<void> saveCredentials({
    required String login,
    required String fullName,
    required String job,
  }) async {
    await _storage.write(key: 'login', value: login);
    await _storage.write(key: 'fullName', value: fullName);
    await _storage.write(key: 'job', value: job);
    await _storage.write(key: 'loggedIn', value: 'true');
  }

  Future<String?> getLogin() async {
    return await _storage.read(key: 'login');
  }

  Future<String?> getFullName() async {
    return await _storage.read(key: 'fullName');
  }

  Future<String?> getJob() async {
    return await _storage.read(key: 'job');
  }

  Future<bool> isLoggedIn() async {
    final value = await _storage.read(key: 'loggedIn');
    return value == 'true';
  }

  Future<void> clearCredentials() async {
    await _storage.deleteAll();
  }
}
