import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:zxing_lib/common.dart';
import 'package:zxing_lib/zxing.dart';

/// Какие коды бывают на складе: штрихкоды производителя (EAN, UPC),
/// этикетки 1С и складских принтеров (Code 128, Code 39), QR и DataMatrix.
const _formats = [
  BarcodeFormat.ean13,
  BarcodeFormat.ean8,
  BarcodeFormat.upcA,
  BarcodeFormat.upcE,
  BarcodeFormat.code128,
  BarcodeFormat.code39,
  BarcodeFormat.itf,
  BarcodeFormat.qrCode,
  BarcodeFormat.dataMatrix,
];

/// Снимок крупнее этого уменьшаем: штрихкод читается и так, а разбор
/// двенадцати мегапикселей на телефоне занимает секунды.
const _maxSide = 1600;

/// Код со снимка [bytes] (JPEG или PNG); null — не нашёлся.
///
/// Разбор — целиком на телефоне, на чистом Dart: сканер с камерой в
/// реальном времени тянет за собой Android-модуль, а такие модули здесь уже
/// ломали сборку (см. pubspec). Снимок никуда не отправляется.
String? decodeBarcode(Uint8List bytes) {
  img.Image? image;
  try {
    image = img.decodeImage(bytes);
  } catch (_) {
    return null;
  }
  if (image == null) return null;
  image = img.bakeOrientation(image);
  final side = image.width > image.height ? image.width : image.height;
  if (side > _maxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: _maxSide)
        : img.copyResize(image, height: _maxSide);
  }
  // Штрихкод сфотографировали поперёк — повернём и попробуем ещё раз.
  return _decode(image) ?? _decode(img.copyRotate(image, angle: 90));
}

/// То же в фоне: экран не замирает, пока разбирается снимок.
Future<String?> decodeBarcodeInBackground(Uint8List bytes) =>
    compute(decodeBarcode, bytes);

String? _decode(img.Image image) {
  final luminances = Uint8List(image.width * image.height);
  var i = 0;
  for (final pixel in image) {
    luminances[i++] =
        ((pixel.r.toInt() + 2 * pixel.g.toInt() + pixel.b.toInt()) ~/ 4);
  }
  final source = RGBLuminanceSource.orig(image.width, image.height, luminances);
  const hints = DecodeHint(tryHarder: true, possibleFormats: _formats);
  for (final binarizer in <Binarizer>[
    HybridBinarizer(source),
    GlobalHistogramBinarizer(source),
  ]) {
    try {
      final text =
          MultiFormatReader().decode(BinaryBitmap(binarizer), hints).text;
      final code = text.trim();
      if (code.isNotEmpty) return code;
    } catch (_) {
      // Не нашёлся этим способом — пробуем следующим.
    }
  }
  return null;
}
