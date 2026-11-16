import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// QR-код, нарисованный самим приложением.
///
/// Чёрное на белом с белой рамкой в четыре клетки — так, как его ждут
/// камеры, — и в тёмной теме тоже: светлый код на тёмном фоне читает не
/// всякий телефон.
class QrView extends StatelessWidget {
  const QrView({super.key, required this.data, this.size = 240});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final image = QrImage(QrCode(
      payload: QrPayload.fromString(data),
      errorCorrectLevel: QrErrorCorrectLevel.medium,
    ));
    return Semantics(
      label: 'QR',
      image: true,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _QrPainter(image)),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);

  final QrImage image;

  static const int _quiet = 4;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final cells = image.moduleCount + _quiet * 2;
    final cell = size.shortestSide / cells;
    final dark = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var row = 0; row < image.moduleCount; row++) {
      for (var col = 0; col < image.moduleCount; col++) {
        if (!image.isDark(row, col)) continue;
        // Клетки чуть внахлёст: без этого между соседними проступают
        // светлые волоски, и камера путается.
        canvas.drawRect(
          Rect.fromLTWH((col + _quiet) * cell, (row + _quiet) * cell,
              cell + 0.5, cell + 0.5),
          dark,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}
