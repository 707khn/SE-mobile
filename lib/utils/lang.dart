import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Язык приложения — в одном месте.
///
/// Прежде он лежал в настройках строками «RU» и «KZ» и сравнивался с ними в
/// пяти файлах. Две беды из этого:
///
/// * «RU» и «KZ» — не коды языков. Из-за этого `supportedLocales` знал только
///   про русский, и всё, что рисует сам Flutter — выбор даты, кнопки «ОК» и
///   «Отмена», меню выделения текста, — оставалось русским даже тогда, когда
///   приложение переключено на казахский;
/// * умолчание разошлось. `main.dart` считал языком по умолчанию русский, а
///   `main_screen_2.dart` при пустой настройке записывал «KZ» — то есть язык
///   зависел от того, какой экран открыли первым.
///
/// Здесь коды настоящие (`ru`, `kk`), а прочитанное со старых телефонов
/// приводится к ним.
class Lang {
  Lang._();

  static const String ru = 'ru';
  static const String kk = 'kk';

  /// Код языка из того, что лежит в настройках.
  ///
  /// Старые сборки писали «RU» и «KZ»; эти значения на телефонах есть и
  /// никуда не денутся, поэтому понимаем и их.
  static String code(String? stored) {
    switch ((stored ?? '').trim().toLowerCase()) {
      case 'kz':
      case 'kk':
        return kk;
      default:
        return ru;
    }
  }

  static Locale locale(String? stored) => Locale(code(stored));

  static bool isKazakh(String? stored) => code(stored) == kk;

  /// Какой язык выбран сейчас.
  static String get current => code(Get.locale?.languageCode);

  /// Готовы ли казахские названия месяцев и дней недели.
  static bool _kazakhDates = false;

  /// Готовит названия месяцев и дней недели.
  ///
  /// Казахские — по возможности: если в intl их для этого языка нет, даты
  /// останутся русскими, а приложение всё равно запустится. Молча падать на
  /// названии месяца из-за языка — худшее, что тут можно сделать.
  static Future<void> initDates() async {
    await initializeDateFormatting(ru);
    try {
      await initializeDateFormatting(kk);
      _kazakhDates = true;
    } catch (_) {
      _kazakhDates = false;
    }
  }

  /// Знает ли казахский сам Flutter — то есть будут ли по-казахски выбор
  /// даты, кнопки «ОК» и «Отмена», меню выделения текста.
  ///
  /// Спрашиваем, а не полагаемся на память: если объявить `supportedLocales`
  /// с языком, которого у Flutter нет, то `MaterialLocalizations.of` не
  /// найдёт перевода и экран упадёт. Нет — значит, эти надписи останутся
  /// русскими, как и были, а текст самого приложения всё равно казахский.
  static bool get flutterKnowsKazakh =>
      GlobalMaterialLocalizations.delegate.isSupported(const Locale(kk));

  /// Языки, которые объявляем Flutter.
  static List<Locale> get supported => <Locale>[
        const Locale(ru),
        if (flutterKnowsKazakh) const Locale(kk),
      ];

  /// Язык, на котором писать даты.
  ///
  /// Раньше во всех шести местах стояло `'ru'` наглухо, и переключённое на
  /// казахский приложение показывало «июля 2026» и «понедельник».
  static String get dates => (_kazakhDates && current == kk) ? kk : ru;
}
