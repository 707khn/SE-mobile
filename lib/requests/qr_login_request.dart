import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/variables.dart';
import '../widgets/qr_camera.dart' show forgetCodeInAddress;

/// Вход на компьютере по QR-коду с телефона (сервер — qr_login.py).
///
/// Компьютер заводит код ([startQrLogin]) и раз в пару секунд спрашивает,
/// подтвердили ли его ([pollQrLogin]). Телефон, где человек уже вошёл,
/// считывает код ([scanQrLogin]) и подтверждает ([answerQrLogin]).

/// Адрес, который зашит в QR-код: веб-версия SE-mobile с кодом в ссылке.
///
/// Ссылкой, а не голым кодом: телефон, наведённый на экран обычной камерой,
/// откроет веб-версию и сразу спросит подтверждение — если в этом браузере
/// человек уже вошёл. Сканер внутри приложения вынимает код из ссылки сам.
String qrLoginLink(String code) => '${AppValues.baseUrl}/web/?pc=$code';

/// Восемь знаков без похожих (0/O, 1/I) — как их выдаёт сервер.
const String _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// Код из того, что считала камера или набрал человек: сам код или ссылка
/// из QR. Не похоже на код — null.
String? qrLoginCodeFrom(String raw) {
  var text = raw.trim();
  final link = RegExp(r'[?&#]pc=([A-Za-z0-9-]+)').firstMatch(text);
  if (link != null) text = link.group(1)!;
  final code = text.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
  if (code.length != 8) return null;
  for (final ch in code.split('')) {
    if (!_alphabet.contains(ch)) return null;
  }
  return code;
}

/// Код, разбитый для глаз: «ABCD 2345».
String qrLoginCodeForEyes(String code) =>
    code.length == 8 ? '${code.substring(0, 4)} ${code.substring(4)}' : code;

// ── Компьютер ───────────────────────────────────────────────────────────────

class QrLoginTicket {
  const QrLoginTicket(
      {required this.secret, required this.code, required this.lifetime});

  /// Знает только этот компьютер: по нему забирают пропуск.
  final String secret;

  /// В QR-коде и на экране.
  final String code;
  final Duration lifetime;
}

/// Новый код для QR. Не ответил сервер — null.
Future<QrLoginTicket?> startQrLogin(String device) async {
  try {
    final response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/api/qr-login/start'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'device': device}),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final secret = body['secret'] as String?;
    final code = body['code'] as String?;
    if (secret == null || code == null) return null;
    return QrLoginTicket(
      secret: secret,
      code: code,
      lifetime: Duration(seconds: (body['expires_in'] as num?)?.toInt() ?? 120),
    );
  } catch (_) {
    return null;
  }
}

enum QrPollStatus { waiting, scanned, approved, rejected, expired, offline }

class QrPoll {
  const QrPoll(this.status, [this.body]);
  final QrPollStatus status;

  /// При [QrPollStatus.approved] — то же, что при обычном входе: пропуск,
  /// логин, имя, должность.
  final Map<String, dynamic>? body;
}

Future<QrPoll> pollQrLogin(String secret) async {
  try {
    final response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/api/qr-login/poll'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'secret': secret}),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return const QrPoll(QrPollStatus.offline);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final status = switch (body['status']) {
      'waiting' => QrPollStatus.waiting,
      'scanned' => QrPollStatus.scanned,
      'approved' => QrPollStatus.approved,
      'rejected' => QrPollStatus.rejected,
      _ => QrPollStatus.expired,
    };
    if (status == QrPollStatus.approved &&
        ((body['token'] as String?) ?? '').isEmpty) {
      return const QrPoll(QrPollStatus.expired);
    }
    return QrPoll(status, body);
  } catch (_) {
    return const QrPoll(QrPollStatus.offline);
  }
}

// ── Телефон ─────────────────────────────────────────────────────────────────

enum QrAnswer { ok, notFound, taken, unauthorized, offline }

QrAnswer _answerOf(http.Response response) {
  switch (response.statusCode) {
    case 200:
      return QrAnswer.ok;
    case 401:
      return QrAnswer.unauthorized;
    case 404:
      return QrAnswer.notFound;
    case 409:
      return QrAnswer.taken;
    default:
      return QrAnswer.offline;
  }
}

/// Телефон считал код. При [QrAnswer.ok] — имя компьютера (может быть
/// пустым).
Future<(QrAnswer, String)> scanQrLogin(String code) async {
  try {
    final response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/api/qr-login/scan'),
          headers: await authHeaders(),
          body: jsonEncode({'code': code}),
        )
        .timeout(const Duration(seconds: 20));
    final answer = _answerOf(response);
    if (answer != QrAnswer.ok) return (answer, '');
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (QrAnswer.ok, (body['device'] as String?) ?? '');
  } catch (_) {
    return (QrAnswer.offline, '');
  }
}

/// Разрешить вход ([approve]) или отказать.
Future<QrAnswer> answerQrLogin(String code, {required bool approve}) async {
  try {
    final response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/api/qr-login/'
              '${approve ? 'confirm' : 'reject'}'),
          headers: await authHeaders(),
          body: jsonEncode({'code': code}),
        )
        .timeout(const Duration(seconds: 20));
    return _answerOf(response);
  } catch (_) {
    return QrAnswer.offline;
  }
}

/// Код из адреса, по которому открыли веб-версию (…/web/?pc=…): телефон
/// навели на QR обычной камерой. Отдаётся один раз — оболочка приложения
/// спросит про него, как только человек войдёт.
String? takeCodeFromAddress() {
  if (!kIsWeb || _addressCodeTaken) return null;
  _addressCodeTaken = true;
  final raw = Uri.base.queryParameters['pc'];
  if (raw == null) return null;
  forgetCodeInAddress();
  return qrLoginCodeFrom(raw);
}

bool _addressCodeTaken = false;
