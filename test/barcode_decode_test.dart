import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:se_mobile/functions/barcode_decode.dart';
import 'package:zxing_lib/zxing.dart';

/// Код, нарисованный как на этикетке: чёрные полосы на белом с полями.
Uint8List _photo(String text, BarcodeFormat format,
    {int width = 600,
    int height = 200,
    bool rotated = false,
    bool jpeg = true}) {
  final matrix = MultiFormatWriter().encode(text, format, width, height);
  var image = img.Image(width: matrix.width + 80, height: matrix.height + 80);
  img.fill(image, color: img.ColorRgb8(235, 235, 230));
  for (var y = 0; y < matrix.height; y++) {
    for (var x = 0; x < matrix.width; x++) {
      if (matrix.get(x, y)) {
        image.setPixelRgb(x + 40, y + 40, 20, 20, 25);
      }
    }
  }
  if (rotated) image = img.copyRotate(image, angle: 90);
  return Uint8List.fromList(
      jpeg ? img.encodeJpg(image, quality: 85) : img.encodePng(image));
}

void main() {
  test('reads a manufacturer EAN-13 from a photo', () {
    expect(decodeBarcode(_photo('4601234567893', BarcodeFormat.ean13)),
        '4601234567893');
  });

  test('reads a 1C label in Code 128, also turned sideways', () {
    expect(decodeBarcode(_photo('00-123', BarcodeFormat.code128)), '00-123');
    expect(
        decodeBarcode(_photo('00-123', BarcodeFormat.code128, rotated: true)),
        '00-123');
  });

  test('reads a QR label', () {
    expect(
        decodeBarcode(_photo('00-200', BarcodeFormat.qrCode,
            width: 300, height: 300, jpeg: false)),
        '00-200');
  });

  test('a photo without a code or not a picture at all gives null', () {
    final blank = img.Image(width: 400, height: 300);
    img.fill(blank, color: img.ColorRgb8(200, 200, 200));
    expect(decodeBarcode(Uint8List.fromList(img.encodeJpg(blank))), isNull);
    expect(decodeBarcode(Uint8List.fromList([1, 2, 3])), isNull);
  });
}
