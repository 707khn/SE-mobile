/// Версия приложения, показывается внизу бокового меню.
///
/// Её ставит сборка (.github/scripts/version.sh): старшие цифры — из
/// pubspec.yaml, номер сборки — число коммитов в main. Руками номер больше не
/// правят: из-за строки version почти каждый PR конфликтовал с main. Сборка
/// передаёт оба значения через --dart-define; у собранного на своём
/// компьютере стоит «dev» и сборка 0.
const String kAppVersion =
    String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

/// Номер сборки (часть после «+»). По нему приложение решает, вышла ли
/// новая версия (app_update.dart).
const String kAppBuild = String.fromEnvironment('APP_BUILD', defaultValue: '0');

/// «1.0.0 (сборка 1)» — то, что видит пользователь.
String appVersionLabel() => '$kAppVersion ($kAppBuild)';
