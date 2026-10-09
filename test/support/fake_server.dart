import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Сервер, который на любой запрос отвечает одним и тем же.
///
/// Обычная заглушка flutter_test отвечает 400 на всё — как nginx, когда
/// служба лежит. Иногда нужен другой ответ: например, 200 со страницей входа
/// в гостевой Wi-Fi вместо JSON. Тогда запрос оборачивают так:
///
///     await HttpOverrides.runWithHttpOverrides(
///         () => fetchSomething(), FakeServer(200, '<html>…'));
class FakeServer extends HttpOverrides {
  FakeServer(int status, String body,
      {this.contentType = 'text/html; charset=utf-8'})
      : answer = ((_, __, ___) => (status, body));

  /// Сервер, который отвечает по запросу: метод, адрес и тело запроса —
  /// код и тело ответа. Нужен, когда ответ зависит от того, о ком спросили.
  FakeServer.routed(this.answer,
      {this.contentType = 'application/json; charset=utf-8'});

  final (int, String) Function(String method, Uri url, String body) answer;
  final String contentType;

  /// Тела запросов — по порядку.
  final List<String> requests = [];

  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client(this);
}

class _Client implements HttpClient {
  _Client(this.server);
  final FakeServer server;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _Request(server, method, url);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Request implements HttpClientRequest {
  _Request(this.server, this.method, this.uri);
  final FakeServer server;

  @override
  final String method;

  @override
  final Uri uri;

  final List<int> _sent = [];

  @override
  final HttpHeaders headers = _Headers({});

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      stream.forEach(_sent.addAll);

  @override
  Future<HttpClientResponse> close() async {
    final body = utf8.decode(_sent, allowMalformed: true);
    server.requests.add(body);
    final (status, answer) = server.answer(method, uri, body);
    return _Response(status, answer, server.contentType);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Response extends StreamView<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, String body, this.contentType)
      : super(Stream<List<int>>.value(utf8.encode(body)));
  final String contentType;

  @override
  final int statusCode;

  @override
  int get contentLength => -1;

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => '';

  @override
  HttpHeaders get headers => _Headers({
        'content-type': [contentType],
      });

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Headers implements HttpHeaders {
  _Headers(this.values);
  final Map<String, List<String>> values;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = ['$value'];
  }

  @override
  void forEach(void Function(String name, List<String> values) action) =>
      values.forEach(action);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
