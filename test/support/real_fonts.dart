import 'dart:io';

import 'package:flutter/services.dart';

/// Шрифт — настоящий Roboto из Flutter, которым запущены проверки: тестовый
/// по умолчанию рисует каждую букву квадратом, и ширина текста выходит
/// ложной.
Future<void> realFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'] ?? '';
  final dir = '$root/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final name in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
    final file = File('$dir/$name');
    if (file.existsSync()) {
      roboto.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
  }
  await roboto.load();
}
