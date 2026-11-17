import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/own_password.dart';
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';
import 'account_request.dart' show settleIssuedPassword;

/// Вход из Safari — значку на экране «Домой» (сервер — web_handoff.py).
///
/// На iPhone значок, поставленный через «Поделиться» → «На экран Домой»,
/// хранит своё отдельно от Safari, и вход из вкладки туда не попадает:
/// значок снова спрашивал логин и пароль. Одно iOS переносит — куки, в ту
/// минуту, когда значок ставят. Поэтому вошедшая вкладка держит у себя
/// куку ([offerLoginToHomeScreenIcon]), а значок при первом запуске
/// предъявляет её и получает свой пропуск ([claimLoginFromSafari]).
///
/// Кука HttpOnly: сама страница её не видит, её ставит и читает сервер.
/// Запросы идут на тот же сайт, с которого открыта веб-версия, — браузер
/// прикладывает куку сам.

/// Вкладка Safari, где уже вошли: оставить куку для будущего значка.
/// Ошибки неважны — не вышло, значок спросит пароль, как раньше.
Future<void> offerLoginToHomeScreenIcon() async {
  if (!iosBrowserTab) return;
  try {
    await http
        .post(Uri.parse('${AppValues.baseUrl}/api/web-handoff'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 15));
  } catch (_) {}
}

/// Значок при первом запуске: забрать вход из Safari.
///
/// true — вошли: пропуск, логин, имя и должность сохранены, дальше —
/// как после обычного входа (придумать код из четырёх цифр). false —
/// передавать нечего или нет связи: обычный экран входа.
Future<bool> claimLoginFromSafari() async {
  if (!iosHomeScreenIcon) return false;
  try {
    final response = await http
        .post(Uri.parse('${AppValues.baseUrl}/api/web-handoff/claim'),
            headers: {'Content-Type': 'application/json'})
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return false;
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final token = (body['token'] as String?) ?? '';
    if (body['status'] != 'approved' || token.isEmpty) return false;
    await SecureStorageHelper.instance.saveCredentials(
      login: (body['login'] as String?) ?? '',
      fullName: (body['full_name'] as String?) ?? '',
      job: (body['job'] as String?) ?? '',
      employeeId: (body['employee_id'] as String?) ?? '',
      token: token,
    );
    final hasPassword = body['has_password'];
    if (hasPassword is bool) await OwnPassword.save(hasPassword);
    // В Safari вошли выданным кодом — во вкладке его не гасят как раз
    // ради значка (см. spendIssuedPasswordHere). Значок вошёл — гасим.
    if (body['must_change_password'] == true) {
      await settleIssuedPassword();
    }
    return true;
  } catch (_) {
    return false;
  }
}
