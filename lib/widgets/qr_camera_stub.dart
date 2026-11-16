import 'package:flutter/material.dart';

/// Есть ли камера для QR-кода на этом устройстве.
bool get qrCameraSupported => false;

/// Почему камера не открылась.
enum QrCameraProblem { denied, unavailable }

class QrCamera extends StatelessWidget {
  const QrCamera({super.key, required this.onCode, required this.onProblem});

  final ValueChanged<String> onCode;
  final ValueChanged<QrCameraProblem> onProblem;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Убрать код из адресной строки — только у веб-версии.
void forgetCodeInAddress() {}

/// Каким браузером открыта веб-версия — только у веб-версии.
String browserDescription() => '';
