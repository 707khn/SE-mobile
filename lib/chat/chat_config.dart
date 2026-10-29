import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../utils/store.dart';

/// Адрес сервера конфиденциального чата SE-chat.
///
/// Зашит в сборку: `flutter build apk --dart-define=CHAT_URL=https://chat…`.
/// Сотрудник его не вводит и подменить не может. Сервер чата отдельный — не
/// api.se-btrz.com: сервер SE-mobile открыт в интернет и разбирает файлы 1С и
/// Excel, а его взлом не должен давать ни метаданных переписки, ни
/// возможности подменить код чата.
///
/// Пока адреса нет, вкладки «Чат» нет совсем: сборки без него выглядят и
/// работают как раньше.
const String _rawChatUrl = String.fromEnvironment('CHAT_URL');

/// Тот же адрес без «/» на конце — так его нормализует и клиент чата.
String get kChatUrl => _rawChatUrl.trim().replaceAll(RegExp(r'/+$'), '');

/// Где в пакете лежит собранный клиент SE-chat (tools/build-chat.sh).
const String kChatAssetDir = 'assets/sechat';

/// Откуда страница чата открывается во встроенном браузере.
///
/// appassets.androidplatform.net зарезервирован Android за файлами самого
/// приложения (WebViewAssetLoader): запросы на него в сеть не уходят, а
/// страница считается защищённой (https), поэтому WebCrypto работает как в
/// браузере. Сервер SE-chat разрешает этот адрес сам.
const String kChatPageUrl =
    'https://appassets.androidplatform.net/assets/flutter_assets/$kChatAssetDir/index.html';

/// Вкладка «Чат» есть, только когда задан сервер. iOS пока не поддержан:
/// для фоновых уведомлений там нужен свой механизм (см. SE-chat docs/MOBILE.md).
bool get chatEnabled =>
    kChatUrl.startsWith('https://') && !kIsWeb && Platform.isAndroid;

/// Фоновые уведомления чата: служба объявлена только в сборке для своего
/// сервера (android/app/src/chat/AndroidManifest.xml), в Google Play её нет.
bool get chatBackgroundNotifyAvailable => chatEnabled && !kFromPlay;
