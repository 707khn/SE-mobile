/// Безопасная зона экрана в браузере: полоска «домой» и скруглённые углы
/// iPhone, вырез сверху.
///
/// На телефоне и компьютере Flutter сам кладёт эти отступы в
/// MediaQuery.padding, и SafeArea / NavigationBar их учитывают. В браузере
/// там всегда нули, поэтому на iPhone нижняя панель уезжала под полоску
/// «домой». Настоящая работа — в веб-сборке (web_safe_area_web.dart): она
/// спрашивает отступы у страницы (web/index.html) и добавляет их в
/// MediaQuery. Вне браузера WebSafeArea просто отдаёт child как есть.
library;

export 'web_safe_area_stub.dart'
    if (dart.library.js_interop) 'web_safe_area_web.dart';
