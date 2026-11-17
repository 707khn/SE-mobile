import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../utils/desktop.dart';

/// Есть ли камера для QR-кода: в приложении на телефоне — да, в программе
/// для компьютера — нет (там код показывают, а не считывают).
bool get qrCameraSupported =>
    !isDesktop && (Platform.isAndroid || Platform.isIOS);

/// Почему камера не открылась.
enum QrCameraProblem { denied, unavailable }

/// Задняя камера телефона и поиск QR-кода в кадре (mobile_scanner).
///
/// На Android распознаёт модуль Google Play Services, а не встроенная в apk
/// модель (android/gradle.properties, useUnbundled): apk раздают по
/// заводской сети, и лишние мегабайты в нём ни к чему. Нет сервисов Google
/// — камера скажет «не открылась», и код наберут руками.
class QrCamera extends StatefulWidget {
  const QrCamera({super.key, required this.onCode, required this.onProblem});

  /// Что прочитано в коде — один раз.
  final ValueChanged<String> onCode;
  final ValueChanged<QrCameraProblem> onProblem;

  @override
  State<QrCamera> createState() => _QrCameraState();
}

class _QrCameraState extends State<QrCamera> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _found = false;
  bool _failed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_found) return;
    for (final barcode in capture.barcodes) {
      final text = barcode.rawValue ?? '';
      if (text.isEmpty) continue;
      _found = true;
      _controller.stop();
      widget.onCode(text);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: _onDetect,
          errorBuilder: (context, error) {
            // Сообщить экрану — после кадра: он перестроится без камеры.
            if (!_failed) {
              _failed = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                widget.onProblem(
                    error.errorCode == MobileScannerErrorCode.permissionDenied
                        ? QrCameraProblem.denied
                        : QrCameraProblem.unavailable);
              });
            }
            return const ColoredBox(color: Colors.black);
          },
        ),
        // Рамка-прицел поверх видео.
        IgnorePointer(
          child: Center(
            child: FractionallySizedBox(
              widthFactor: 0.65,
              child: AspectRatio(
                aspectRatio: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white, width: 3),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Убрать код из адресной строки — только у веб-версии.
void forgetCodeInAddress() {}

/// Каким браузером открыта веб-версия — только у веб-версии.
String browserDescription() => '';
