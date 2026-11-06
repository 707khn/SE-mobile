/// Открыт ли SE-mobile значком с экрана «Домой», а не вкладкой браузера.
///
/// Спросить об этом можно только у браузера, поэтому настоящий ответ — в
/// веб-сборке (home_screen_icon_web.dart). Телефону и компьютеру вкладок
/// не бывает: там всегда false.
library;

export 'home_screen_icon_stub.dart'
    if (dart.library.js_interop) 'home_screen_icon_web.dart';
