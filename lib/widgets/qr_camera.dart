/// Камера, считывающая QR-код, — для входа на компьютере с телефона.
///
/// В веб-версии камеру даёт браузер (jsQR, qr_camera_web.dart), в
/// приложении для телефона — mobile_scanner (qr_camera_native.dart). В
/// программе для компьютера камеры нет: там код показывают
/// ([qrCameraSupported] — false).
library;

export 'qr_camera_native.dart' if (dart.library.js_interop) 'qr_camera_web.dart';
