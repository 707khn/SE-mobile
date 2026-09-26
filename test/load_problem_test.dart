import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:se_mobile/utils/load_problem.dart';

void main() {
  test('нет соединения — «нет связи», а не «ошибка сервера»', () {
    expect(problemOf(SocketException('Failed host lookup')),
        LoadProblem.offline);
    expect(problemOf(http.ClientException('Connection closed')),
        LoadProblem.offline);
    expect(problemOf(HandshakeException('bad cert')),
        LoadProblem.offline);
  });

  test('не дождались — «долго не отвечает»', () {
    expect(problemOf(TimeoutException('60s')), LoadProblem.slow);
  });

  test('всё остальное — сбой на стороне сервера', () {
    expect(problemOf(const FormatException('not json')), LoadProblem.server);
    expect(problemForStatus(500), LoadProblem.server);
    expect(problemForStatus(502), LoadProblem.server);
  });

  test('403 — «нет доступа»: повтор тут не поможет', () {
    expect(problemForStatus(403), LoadProblem.denied);
  });

  test('причина переживает путь через словарь и через исключение', () {
    for (final p in LoadProblem.values) {
      expect(problemIn({problemKey: p.name}), p);
      expect(problemOfAny(LoadFailure(p)), p);
    }
    expect(problemIn({'message': 'Failure'}), isNull);
    expect(problemIn({problemKey: 'что-то новое'}), isNull);
    expect(problemOfAny(TimeoutException('x')), LoadProblem.slow);
  });

  test('техническая строка — короткая, в одну строку и называет причину', () {
    final detail = problemDetail(SocketException(
        "Failed host lookup: 'api.se-btrz.com'\n  (OS Error: errno = 7)"));
    expect(detail, contains('Failed host lookup'));
    expect(detail, isNot(contains('\n')));
    expect(problemDetail(FormatException('x' * 500)).length, lessThanOrEqualTo(161));
  });
}
