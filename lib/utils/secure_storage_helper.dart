import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageHelper {
  SecureStorageHelper._();
  static final SecureStorageHelper instance = SecureStorageHelper._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<void> saveCredentials({
    required String login,
    required String password,
    required String fullName,
    required String job,
    required String employeeId,
    String? token,
  }) async {
    await _storage.write(key: 'login', value: login);
    await _storage.write(key: 'password', value: password);
    await _storage.write(key: 'employeeId', value: employeeId);
    await _storage.write(key: 'fullName', value: fullName);
    await _storage.write(key: 'job', value: job);
    await _storage.write(key: 'loggedIn', value: 'true');
    if (token != null && token.isNotEmpty) {
      await _storage.write(key: 'token', value: token);
    }
  }

  /// Пропуск, который сервер выдал при входе. Его ждут все запросы, кроме
  /// самого входа.
  Future<String?> getToken() async => _storage.read(key: 'token');

  Future<void> saveToken(String token) async {
    if (token.isNotEmpty) await _storage.write(key: 'token', value: token);
  }

  /// Код для входа в приложение — четыре цифры.
  ///
  /// Лежит рядом с пропуском, в том же защищённом хранилище (Keystore на
  /// Android, Keychain на iOS). Хеш здесь ничего бы не добавил: в этом же
  /// хранилище лежит и сам пароль, так что код защищён ровно настолько же.
  /// Он и нужен для другого — чтобы в оставленный без присмотра телефон не
  /// заглянул посторонний, а не чтобы устоять против вскрытия памяти.
  Future<String?> getPin() async => _storage.read(key: 'pin');

  Future<bool> hasPin() async {
    final pin = await _storage.read(key: 'pin');
    return pin != null && pin.length == 4;
  }

  Future<void> savePin(String pin) async {
    await _storage.write(key: 'pin', value: pin);
    await _storage.delete(key: 'pinFails');
  }

  /// Сколько раз подряд код ввели неверно. Переживает перезапуск приложения:
  /// иначе счётчик обнулялся бы простым закрытием окна.
  Future<int> getPinFails() async {
    final value = await _storage.read(key: 'pinFails');
    return int.tryParse(value ?? '0') ?? 0;
  }

  Future<int> bumpPinFails() async {
    final next = await getPinFails() + 1;
    await _storage.write(key: 'pinFails', value: '$next');
    return next;
  }

  Future<void> resetPinFails() async => _storage.delete(key: 'pinFails');

  Future<String?> getLogin() async {
    return await _storage.read(key: 'login');
  }

  Future<String?> getPassword() async {
    return await _storage.read(key: 'password');
  }

  Future<String?> getEmployeeId() async {
    return await _storage.read(key: 'employeeId');
  }

  Future<void> saveEmployeeId(String id) async {
    await _storage.write(key: 'employeeId', value: id);
  }

  /// Refreshes the cached profile after HR changes a job title or department,
  /// so a signed-in user does not have to log out to pick the change up.
  Future<void> saveProfile({
    required String fullName,
    required String job,
    required String employeeId,
  }) async {
    if (employeeId.isNotEmpty) {
      await _storage.write(key: 'employeeId', value: employeeId);
    }
    if (fullName.isNotEmpty) {
      await _storage.write(key: 'fullName', value: fullName);
    }
    if (job.isNotEmpty) {
      await _storage.write(key: 'job', value: job);
    }
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
