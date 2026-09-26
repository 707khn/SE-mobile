import 'dart:async';
import 'dart:io' show HandshakeException, SocketException;

import 'package:http/http.dart' as http;

/// Почему не загрузилось — настолько, насколько это видно с телефона.
///
/// Раньше на всё был один ответ: «Ошибка подключения к серверу». Человек без
/// мобильного интернета и человек, которому сервер ответил ошибкой, видели
/// одно и то же, и ни тот ни другой не знал, что делать: включать ли
/// интернет, ждать ли, звонить ли в ОИТиС.
enum LoadProblem {
  /// Соединиться не удалось. Чаще всего нет интернета; реже — сервер лежит,
  /// и отличить одно от другого телефон не может. Так и говорим.
  offline,

  /// Соединились, но ответа не дождались.
  slow,

  /// Сервер ответил, но ошибкой.
  server,

  /// Сервер ответил «не для вас» (403). Повтор не поможет.
  denied,
}

/// Причина по исключению, пойманному вокруг запроса.
LoadProblem problemOf(Object error) {
  if (error is TimeoutException) return LoadProblem.slow;
  if (error is SocketException ||
      error is HandshakeException ||
      error is http.ClientException) {
    return LoadProblem.offline;
  }
  return LoadProblem.server;
}

/// Причина по коду ответа, отличному от 200.
LoadProblem problemForStatus(int status) =>
    status == 403 ? LoadProblem.denied : LoadProblem.server;

/// Запросы, которые возвращают словарь, кладут причину под этим ключом.
const String problemKey = 'problem';

/// Причина из такого словаря; `null`, если её не положили.
LoadProblem? problemIn(Map<String, dynamic> result) =>
    LoadProblem.values.asNameMap()[result[problemKey]];

/// Исключение для запросов, которые при неудаче бросают, а не возвращают.
class LoadFailure implements Exception {
  const LoadFailure(this.problem, [this.detail = '']);

  final LoadProblem problem;
  final String detail;

  @override
  String toString() => 'LoadFailure(${problem.name}) $detail';
}

/// Причина по чему угодно, пойманному в `catch` на экране.
LoadProblem problemOfAny(Object error) =>
    error is LoadFailure ? error.problem : problemOf(error);
