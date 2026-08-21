import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
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

  static Future<void> registerToken(String employeeId) async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;

      await http.post(
        Uri.parse('${AppValues.baseUrl}/api/fcm-token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'employee_id': employeeId, 'token': token}),
      );

      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        await http.post(
          Uri.parse('${AppValues.baseUrl}/api/fcm-token'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'employee_id': employeeId, 'token': newToken}),
        );
      });
    } catch (_) {}
  }

  static Future<void> unregisterToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      await http.delete(
        Uri.parse('${AppValues.baseUrl}/api/fcm-token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'token': token}),
      );
    } catch (_) {}
  }
}
