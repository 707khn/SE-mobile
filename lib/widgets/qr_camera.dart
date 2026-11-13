/// Камера, считывающая QR-код, — для входа на компьютере с телефона.
///
/// Есть только в веб-версии: ею открывают SE-mobile на iPhone, а браузер
/// даёт камеру сам, без лишних модулей в сборке. В приложении для Android и
/// на компьютере камеры здесь нет — там код набирают руками
/// ([qrCameraSupported] — false).
library;

export 'qr_camera_stub.dart' if (dart.library.js_interop) 'qr_camera_web.dart';
