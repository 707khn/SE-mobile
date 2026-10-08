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
  FakeServer(this.status, this.body,
      {this.contentType = 'text/html; charset=utf-8'});

  final int status;
  final String body;
  final String contentType;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client(this);
}

class _Client implements HttpClient {
  _Client(this.server);
  final FakeServer server;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _Request(server);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Request implements HttpClientRequest {
  _Request(this.server);
  final FakeServer server;

  @override
  final HttpHeaders headers = _Headers({});

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<HttpClientResponse> close() async => _Response(server);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Response extends StreamView<List<int>> implements HttpClientResponse {
  _Response(this.server)
      : super(Stream<List<int>>.value(utf8.encode(server.body)));
  final FakeServer server;

  @override
  int get statusCode => server.status;

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
        'content-type': [server.contentType],
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
