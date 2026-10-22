import 'dart:async';
import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:se_mobile/utils/api.dart';
import 'package:se_mobile/utils/variables.dart';

class FcmService {
  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initSettings =
        InitializationSettings(android: androidSettings);
    await _localNotifications.initialize(initSettings);

    await FirebaseMessaging.instance
        .requestPermission(alert: true, badge: true, sound: true);
  }

  /// Каналы уведомлений по поводам.
  ///
  /// Раздельно, а не одним каналом на всё: Android даёт человеку отключить
  /// канал, не отключая приложение целиком. Сторожу нужны проходы турникета,
  /// остальным — зарплата и столовая, и пусть каждый оставит своё.
  static const Map<String, List<String>> _channels = {
    'payslip': ['payslip_channel', 'Зарплата'],
    'menu': ['menu_channel', 'Столовая'],
    'news': ['news_channel', 'Новости и объявления'],
    'document': ['document_channel', 'Документы предприятия'],
    'turnstile': ['turnstile_channel', 'Проходы турникета'],
  };

  static AndroidNotificationDetails _androidDetails(String? type) {
    final channel = _channels[type] ?? const ['general_channel', 'Прочее'];
    return AndroidNotificationDetails(
      channel[0],
      channel[1],
      importance: Importance.high,
      priority: Priority.high,
    );
  }

  static void setupForegroundHandler() {
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final notification = message.notification;
      if (notification == null) return;
      _localNotifications.show(
        notification.hashCode,
        notification.title,
        notification.body,
        NotificationDetails(
          android: _androidDetails(message.data['type'] as String?),
        ),
      );
    });
  }

  /// Подписка на смену токена — одна на весь процесс: раньше каждая
  /// регистрация добавляла ещё одну.
  static StreamSubscription<String>? _refresh;

  /// Firebase поднят: без google-services.json его нет, и тогда
  /// уведомлений нет вовсе — молча, приложение работает и без них.
  static bool get _ready => Firebase.apps.isNotEmpty;

  /// Привязать этот телефон к вошедшему сотруднику.
  ///
  /// Раньше функция была, но её никто не вызывал, а пропуска она не
  /// посылала — после включения проверки входа сервер отказал бы ей. То есть
  /// уведомления не заработали бы и после подключения Firebase.
  static Future<void> registerToken(String employeeId) async {
    if (!_ready || employeeId.isEmpty) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      await _send(employeeId, token);
      await _refresh?.cancel();
      _refresh = FirebaseMessaging.instance.onTokenRefresh
          .listen((newToken) => _send(employeeId, newToken));
    } catch (_) {}
  }

  static Future<void> _send(String employeeId, String token) async {
    try {
      await http
          .post(
            Uri.parse('${AppValues.baseUrl}/api/fcm-token'),
            headers: await authHeaders(),
            body: jsonEncode({'employee_id': employeeId, 'token': token}),
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  /// Отвязать телефон при выходе — пока пропуск ещё действует.
  ///
  /// Иначе после смены пользователя на этом телефоне продолжали бы
  /// появляться уведомления прежнего: о его листке, его проходах. Токен
  /// заодно сбрасывается, и следующий вошедший получит новый.
  ///
  /// Сам токен сбрасывается и тогда, когда сервер не ответил: без связи
  /// раньше дело до сброса не доходило, и уведомления прежнего продолжали
  /// приходить, пока сервер помнил его токен. Сброшенный токен Firebase
  /// больше не доставляет, что бы ни помнил сервер.
  ///
  /// Каждый шаг ограничен по времени: без связи getToken может ждать долго,
  /// а человек нажал «Выйти» и смотрит на экран.
  static Future<void> unregisterToken() async {
    if (!_ready) return;
    await _refresh?.cancel();
    _refresh = null;
    try {
      final token = await FirebaseMessaging.instance
          .getToken()
          .timeout(const Duration(seconds: 5));
      if (token != null) {
        await http
            .delete(
              Uri.parse('${AppValues.baseUrl}/api/fcm-token'),
              headers: await authHeaders(),
              body: jsonEncode({'token': token}),
            )
            .timeout(const Duration(seconds: 8));
      }
    } catch (_) {}
    try {
      await FirebaseMessaging.instance
          .deleteToken()
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }
}
