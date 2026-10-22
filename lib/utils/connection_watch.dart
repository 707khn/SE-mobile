import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'variables.dart';

/// Следит, не вернулась ли связь, пока экран показывает сохранённое.
///
/// Раньше сохранённое так и висело, пока человек сам не потянет экран вниз:
/// вышел из цеха, связь давно есть, а меню всё «от 7:40». Теперь, пока на
/// каком-нибудь экране есть пометка «показано сохранённое», приложение
/// время от времени стучится на сервер и, когда тот ответил, обновляет
/// экраны само.
///
/// Стучимся не в любой адрес, а в свой сервер: телефон может «быть в сети»,
/// сидя в гостевом Wi-Fi без интернета, — нам важно, отвечает ли сервер.
/// Отдельный пакет для слежения за сетью поэтому и не нужен: он сказал бы
/// только, что Wi-Fi включён.
class ConnectionWatch with WidgetsBindingObserver {
  ConnectionWatch._();
  static final ConnectionWatch instance = ConnectionWatch._();

  /// Паузы между попытками: сначала часто — человек обычно выходит из цеха
  /// и ждёт, — потом раз в минуту, чтобы не сажать батарею.
  static const List<Duration> delays = [
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 40),
    Duration(seconds: 60),
  ];

  /// Проверка сервера. Подменяется в тестах.
  @visibleForTesting
  static Future<bool> Function() probe = _probeServer;

  final StreamController<void> _restored = StreamController<void>.broadcast();

  /// Срабатывает, когда сервер снова ответил.
  Stream<void> get restored => _restored.stream;

  int _holders = 0;
  int _step = 0;
  Timer? _timer;
  bool _probing = false;
  DateTime? _lastRestored;

  /// Экран показывает сохранённое — начинаем следить.
  void hold() {
    _holders++;
    if (_holders > 1) return;
    WidgetsBinding.instance.addObserver(this);
    // Только что обновлялись по возвращении связи, а экран снова на
    // сохранённом — сервер отвечает, но этот адрес сбоит. Тогда не дёргаем
    // его каждые десять секунд, а сразу переходим на раз в минуту.
    final recent = _lastRestored != null &&
        DateTime.now().difference(_lastRestored!) < const Duration(minutes: 2);
    _step = recent ? delays.length - 1 : 0;
    _schedule();
  }

  /// Пометка ушла: данные свежие или экран закрыт.
  void release() {
    if (_holders == 0) return;
    _holders--;
    if (_holders > 0) return;
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  /// Для тестов: сколько экранов ждут связи.
  @visibleForTesting
  int get holders => _holders;

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(delays[_step], check);
    if (_step < delays.length - 1) _step++;
  }

  /// Проверить сейчас, не дожидаясь паузы.
  Future<void> check() async {
    if (_holders == 0 || _probing) return;
    _probing = true;
    bool ok;
    try {
      ok = await probe();
    } catch (_) {
      ok = false;
    }
    _probing = false;
    if (_holders == 0) return;
    if (ok) {
      _lastRestored = DateTime.now();
      // Экраны, которые и после обновления остались на сохранённом, ждут
      // дальше, но уже раз в минуту.
      _step = delays.length - 1;
      _restored.add(null);
    }
    if (_holders > 0) _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Вернулись в приложение — самое вероятное время, когда связь уже есть.
    if (state == AppLifecycleState.resumed) check();
  }

  static Future<bool> _probeServer() async {
    try {
      final response = await http
          .get(Uri.parse('${AppValues.baseUrl}/api/app/latest'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return false;
      // Страница входа в гостевой Wi-Fi тоже отвечает 200 — но не JSON.
      return jsonDecode(response.body) is Map;
    } catch (_) {
      return false;
    }
  }
}
