import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';

/// Чем закончилась смена пароля. Сервер отвечает кодом, а человеку нужно
/// сказать словами, что именно не так.
enum PasswordChangeResult {
  ok,
  wrongOldPassword,
  tooShort,
  sameAsLogin,
  tooSimple,
  noAccount,
  networkError,
}

Future<PasswordChangeResult> changePassword({
  required String oldPassword,
  required String newPassword,
}) async {
  try {
    final response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/change-password'),
          headers: await authHeaders(),
          body: jsonEncode({
            'old_password': oldPassword,
            'new_password': newPassword,
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode == 401) {
      await returnToLogin();
      return PasswordChangeResult.networkError;
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200 && body['message'] == 'Success') {
      // Сервер погасил все пропуска и выдал новый — сохраняем, иначе
      // следующий же запрос улетит с недействительным.
      await SecureStorageHelper.instance.saveToken((body['token'] as String?) ?? '');
      return PasswordChangeResult.ok;
    }
    switch (body['error']) {
      case 'wrong_password':
        return PasswordChangeResult.wrongOldPassword;
      case 'too_short':
        return PasswordChangeResult.tooShort;
      case 'same_as_login':
        return PasswordChangeResult.sameAsLogin;
      case 'too_simple':
        return PasswordChangeResult.tooSimple;
      case 'no_account':
        return PasswordChangeResult.noAccount;
      default:
        return PasswordChangeResult.networkError;
    }
  } on TimeoutException {
    return PasswordChangeResult.networkError;
  } catch (_) {
    return PasswordChangeResult.networkError;
  }
}

/// Учётная запись глазами администратора.
class AccountRow {
  const AccountRow({
    required this.login,
    required this.fullName,
    required this.mustChangePassword,
    required this.isActive,
    required this.lastLoginAt,
  });

  final String login;
  final String fullName;
  final bool mustChangePassword;
  final bool isActive;

  /// Null — человек ни разу не заходил.
  final DateTime? lastLoginAt;

  bool get neverSignedIn => lastLoginAt == null;

  factory AccountRow.fromJson(Map<String, dynamic> json) => AccountRow(
        login: (json['login'] as String?) ?? '',
        fullName: (json['full_name'] as String?) ?? '',
        mustChangePassword: (json['must_change_password'] as bool?) ?? false,
        isActive: (json['is_active'] as bool?) ?? true,
        lastLoginAt: (json['last_login_at'] as String?) == null
            ? null
            : DateTime.tryParse(json['last_login_at'] as String),
      );
}

Future<List<AccountRow>> fetchAccounts() async {
  final response = await http
      .get(
        Uri.parse('${AppValues.baseUrl}/api/admin/accounts'),
        headers: await authHeaders(),
      )
      .timeout(const Duration(seconds: 30));
  if (await handledUnauthorized(response)) return const <AccountRow>[];
  if (response.statusCode != 200) {
    throw Exception('HTTP ${response.statusCode}');
  }
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  return ((body['accounts'] as List<dynamic>?) ?? [])
      .map((e) => AccountRow.fromJson(e as Map<String, dynamic>))
      .toList();
}

/// Сбрасывает пароль сотрудника. Возвращает временный пароль, который надо
/// ему передать, или null при неудаче.
Future<String?> resetPassword(String login) async {
  try {
    final response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/api/admin/accounts/$login/reset'),
          headers: await authHeaders(),
        )
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) return null;
    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['temporary_password'] as String?;
  } catch (_) {
    return null;
  }
}
