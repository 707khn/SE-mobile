/// Версия приложения, показывается внизу бокового меню.
///
/// Должна совпадать с полем `version` в pubspec.yaml — по ней в поддержке
/// понимают, какая сборка стоит у сотрудника. Меняете pubspec — меняйте и здесь.
const String kAppVersion = '1.5.0';

/// Номер сборки (часть после «+» в pubspec.yaml).
const String kAppBuild = '7';

/// «1.0.0 (сборка 1)» — то, что видит пользователь.
String appVersionLabel() => '$kAppVersion ($kAppBuild)';
