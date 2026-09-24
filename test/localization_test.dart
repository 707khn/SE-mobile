import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/utils/localization.dart';

/// Ключ, забытый в одном из языков, GetX показывает как есть: человек видит
/// на экране «rollout_apk_none» вместо надписи. Заметить это можно только
/// переключившись на казахский и дойдя до нужного экрана — то есть почти
/// никогда.
void main() {
  final keys = LocaleString().keys;

  test('оба языка на месте', () {
    expect(keys.containsKey('RU'), isTrue);
    expect(keys.containsKey('KZ'), isTrue);
  });

  test('набор ключей совпадает', () {
    final ru = keys['RU']!.keys.toSet();
    final kz = keys['KZ']!.keys.toSet();
    expect(ru.difference(kz), isEmpty, reason: 'нет в казахском');
    expect(kz.difference(ru), isEmpty, reason: 'нет в русском');
  });

  test('пустых надписей нет', () {
    for (final entry in keys.entries) {
      for (final pair in entry.value.entries) {
        expect(pair.value.trim(), isNotEmpty,
            reason: '${entry.key}: ${pair.key} пустой');
      }
    }
  });

  test('подстановки совпадают в обоих языках', () {
    // «Вышла версия @version» без @version в казахском оставит человека без
    // номера версии — и никто не заметит.
    final pattern = RegExp(r'@[a-zA-Z_]+');
    final ru = keys['RU']!;
    final kz = keys['KZ']!;
    for (final key in ru.keys) {
      final inRu = pattern.allMatches(ru[key]!).map((m) => m.group(0)!).toSet();
      // Нет ключа в казахском — про это уже сказала проверка выше;
      // здесь не падаем второй раз, а просто видим пустой набор.
      final inKz =
          pattern.allMatches(kz[key] ?? '').map((m) => m.group(0)!).toSet();
      expect(inKz, inRu, reason: 'подстановки разошлись в «$key»');
    }
  });
}
