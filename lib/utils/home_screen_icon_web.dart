import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Открыт ли SE-mobile значком с экрана «Домой», а не вкладкой браузера.
///
/// Safari на iPhone отвечает свойством navigator.standalone, остальные
/// браузеры — правилом display-mode: значок открывает приложение в режиме
/// standalone из manifest.json. Не удалось спросить — считаем вкладкой.
bool get openedFromHomeScreen {
  try {
    final navigator = globalContext.getProperty<JSObject?>('navigator'.toJS);
    // Есть только у Safari на iPhone и iPad.
    final standalone = navigator?.getProperty<JSBoolean?>('standalone'.toJS);
    if (standalone?.toDart ?? false) return true;
    final query = globalContext.callMethod<JSObject?>(
        'matchMedia'.toJS, '(display-mode: standalone)'.toJS);
    return query?.getProperty<JSBoolean?>('matches'.toJS)?.toDart ?? false;
  } catch (_) {
    return false;
  }
}
